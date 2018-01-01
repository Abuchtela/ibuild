import Foundation

enum BuilderError: LocalizedError {
    case packageNotFound(String)

    var errorDescription: String? {
        switch self {
            case .packageNotFound(let name): return "Builder could not be created, because the package to build (\(name)) was not found."
        }
    }
}

class Builder {
    static func forPackage(_ package: Package, packageRoot: URL, projectSourceMap: ProjectSourceMap, buildRoot: URL) throws -> Builder? {
        guard let buildProperties = package.build else {
            return nil
        }

        let sourceRoot: URL
        if let location = buildProperties.location {
            guard let locationOnDisk = projectSourceMap.location(ofProjectAt: try location.remoteLocation()) else {
                throw BuilderError.packageNotFound(package.name)
            }
            sourceRoot = locationOnDisk
        } else {
            sourceRoot = packageRoot
        }

        let builderClass: Builder.Type
        switch buildProperties.buildSystem {
            case .cmake: builderClass = CMakeBuilder.self 
            case .make: builderClass = MakeBuilder.self 
            case .xcode: builderClass = XcodeBuilder.self 
        }
        return try builderClass.init(buildProperties: buildProperties, packageName: package.name, packageRoot: packageRoot, sourceRoot: sourceRoot, buildRoot: buildRoot)
    }

    let packageName: String
    let buildProperties: Package.BuildProperties
    let env: [String: String]

    let architectures: [String]
    let platformName: String
    /// Root of the package that's building the library
    let packageRoot: URL
    /// Root of the library to be built
    let sourceRoot: URL
    let buildRoot: URL
    let buildProducts: URL
    let sysroot: URL
    let deploymentTarget: String

    required init(buildProperties: Package.BuildProperties, packageName: String, packageRoot: URL, sourceRoot: URL, buildRoot: URL) throws {
        self.buildProperties = buildProperties
        self.packageName = packageName
        self.packageRoot = packageRoot
        self.sourceRoot = sourceRoot
        self.buildRoot = buildRoot

        let environment = ProcessInfo.processInfo.environment
        if let tmpDir = environment["CONFIGURATION_TEMP_DIR"] {
            self.buildProducts = URL(fileURLWithPath: tmpDir).appendingPathComponent(sourceRoot.lastPathComponent)
        } else {
            self.buildProducts = buildRoot.appendingPathComponent("products").appendingPathComponent(sourceRoot.lastPathComponent)
        }

        if let archs = environment["ARCHS"] {
            self.architectures = archs.components(separatedBy: .whitespaces)
        } else {
            self.architectures = ["arm64"]
        }
        if let platformName = environment["PLATFORM_NAME"] {
            self.platformName = platformName
        } else {
            self.platformName = "iphoneos"
        }

        self.sysroot = URL(fileURLWithPath: try Command.tryExec("/usr/bin/xcrun", ["-sdk", self.platformName, "--show-sdk-path"]))
    
        if let dtPrefix = environment["DEPLOYMENT_TARGET_CLANG_PREFIX"], let dtName = environment["DEPLOYMENT_TARGET_CLANG_ENV_NAME"], let dt = environment[dtName] {
            self.deploymentTarget = dtPrefix + dt
        } else {
            self.deploymentTarget = "-miphoneos-version-min=9.0"
        }

        self.env = [
            "CC": try Command.tryExec("/usr/bin/xcrun", ["-find", "clang"]),
            "CXX": try Command.tryExec("/usr/bin/xcrun", ["-find", "clang++"]),
            "AR": try Command.tryExec("/usr/bin/xcrun", ["-find", "ar"]),
            "RANLIB": try Command.tryExec("/usr/bin/xcrun", ["-find", "ranlib"]),
            "PKGROOT": self.packageRoot.path,
            "SRCROOT": self.sourceRoot.path,
            "SDKROOT": self.sysroot.path,
            "BUILDROOT": self.buildRoot.path
        ]

        try self.setup()
    }

    fileprivate func setup() throws {
    }

    func build() throws {
        guard let libraryOutputs = self.buildProperties.outputs else {
            print("No library outputs. Skipping build.")
            return
        }

        var archOutputs: [String: URL] = [:]
        for arch in architectures {
            print("Configuring for architecture: \(arch)")

            let outputForArch = buildProducts.appendingPathComponent(arch)

            let configureOutput = outputForArch.appendingPathComponent("configure")
            let buildOutput = outputForArch.appendingPathComponent("build")
            archOutputs[arch] = buildOutput

            // Don't build if already exists
            var hasBuilt = true
            for libraryName in libraryOutputs {
                if !FileManager.default.fileExists(atPath: buildOutput.appendingPathComponent(libraryName).path) {
                    hasBuilt = false
                }
            }
            if hasBuilt {
                print("Already built all libraries for architecture: \(arch).")
                continue
            }

            try FileManager.default.createDirectory(atPath: configureOutput.path, withIntermediateDirectories: true, attributes: nil)
            try FileManager.default.createDirectory(atPath: buildOutput.path, withIntermediateDirectories: true, attributes: nil)

            try self.configure(
                architecture: arch, 
                inURL: configureOutput,
                buildOutputURL: buildOutput
            )
            try self.make(
                fromURL: configureOutput
            )
            try self.install(
                fromURL: configureOutput,
                toURL: buildOutput
            )
        }

        // Copy headers and pkgconfig
        if let arch = architectures.first {
            let archOutput = archOutputs[arch]!
            try self.copyHeadersAndMetadata(fromURL: archOutput, toURL: buildRoot)
            try self.copyHeadersAndMetadata(fromURL: archOutput, toURL: buildRoot.appendingPathComponent(self.packageName), isPackageSpecific: true)
        }

        // LIPO to create fat binary for each library
        for libraryName in libraryOutputs {
            let archMap = architectures.map { arch in
                return (arch, archOutputs[arch]!.appendingPathComponent(libraryName))
            }
            try self.lipo(
                from: archMap, 
                toURL: buildRoot.appendingPathComponent(libraryName)
            )
            try self.lipo(
                from: archMap, 
                toURL: buildRoot.appendingPathComponent(self.packageName).appendingPathComponent(libraryName)
            )
        }
    }

    fileprivate func configure(architecture: String, inURL url: URL, buildOutputURL: URL) throws {}

    fileprivate func make(fromURL url: URL) throws {}

    fileprivate func install(fromURL url: URL, toURL: URL) throws {}

    fileprivate func lipo(from architectureMap: [(architecture: String, url: URL)], toURL: URL) throws {
        try FileManager.default.createDirectory(atPath: toURL.deletingLastPathComponent().path, withIntermediateDirectories: true, attributes: nil)

        print("Merging libraries \(architectureMap) to fat library at \(toURL)")
        var args = ["-create", "-output", toURL.path]
        for (arch, url) in architectureMap {
            args += ["-arch", arch, url.path]
        }

        try Command.trySpawn(
            "/usr/bin/lipo",
            args
        )
    }

    fileprivate func copyHeadersAndMetadata(fromURL url: URL, toURL: URL, isPackageSpecific: Bool = false) throws {
        try FileManager.default.createDirectory(atPath: toURL.path, withIntermediateDirectories: true, attributes: nil)
        
        // Copy headers
        let headersURL = url.appendingPathComponent("include")
        if FileManager.default.fileExists(atPath: headersURL.path) {
            let headersRoot = buildRoot.appendingPathComponent("include")
            try FileManager.default.createDirectory(atPath: headersRoot.path, withIntermediateDirectories: true, attributes: nil)
            try Command.cp(from: headersURL, to: toURL)
        }

        // Copy pkgconfig
        let pkgconfigURL = url.appendingPathComponent("lib").appendingPathComponent("pkgconfig")
        if !isPackageSpecific && FileManager.default.fileExists(atPath: pkgconfigURL.path) {
            let libRoot = toURL.appendingPathComponent("lib")
            let pkgconfigRoot = libRoot.appendingPathComponent("pkgconfig")
            try FileManager.default.createDirectory(atPath: pkgconfigRoot.path, withIntermediateDirectories: true, attributes: nil)
            try Command.cp(from: pkgconfigURL, to: libRoot)

            // Replace arch output path with new path for each file
            for path in try FileManager.default.contentsOfDirectory(at: pkgconfigRoot, includingPropertiesForKeys: nil, options: []) {
                try String(contentsOf: path).replacingOccurrences(of: url.path, with: toURL.path).write(to: path, atomically: true, encoding: .utf8)
            }
        }

        // Copy swiftmodules
        let swiftmoduleURL = url.appendingPathComponent("swiftmodules")
        if FileManager.default.fileExists(atPath: swiftmoduleURL.path) {
            try Command.cp(from: swiftmoduleURL, to: toURL)
        }

        if isPackageSpecific, let auxiliary = self.buildProperties.auxiliaryFiles {
            for path in auxiliary {
                try Command.cp(from: packageRoot.appendingPathComponent(path), to: toURL)
            }
        }
    }

    fileprivate func applyEnvToArgs(_ args: [String]) -> [String] {
        // Replace $#SOMETHING# with env[SOMETHING]
        let regex = try! NSRegularExpression(pattern: "\\$\\#([A-Z]*?)\\#", options: [])
        return args.map { arg in 
            var arg = arg
            for result in regex.matches(in: arg, range: NSMakeRange(0, arg.utf16.count)) {
                let range = result.range(at: 1)
                let key = (arg as NSString).substring(with: range)

                if let value = self.env[key] {
                    print("Replacing \(key) with \(value)")
                    arg = (arg as NSString).replacingCharacters(in: result.range(at: 0), with: self.env[key] ?? "")
                }
            }
            return arg
        }
    }
}

class MakeBuilder: Builder {

    override func setup() throws {
        try super.setup()
    }

    override func build() throws {
        print("Building package \(self.packageName) with make...")
        try super.build()
    }

    override func configure(architecture: String, inURL url: URL, buildOutputURL: URL) throws {
        let configureScript = self.sourceRoot.appendingPathComponent("configure")

        var args = [
            "-arch \(architecture)",
            "-isysroot \(self.sysroot.path)",
            "\(self.deploymentTarget)",
            "-fembed-bitcode",
            "--prefix=\(buildOutputURL.path)"
        ]
        if let packageArgs = self.buildProperties.buildArgs {
            args = packageArgs + args
        }
        if let packageArchSpecificArgs = self.buildProperties.buildArchSpecificArgs?[self.platformName]?[architecture] {
            args = packageArchSpecificArgs + args
        }

        args = applyEnvToArgs(args)

        print("Running \(configureScript.path) with arguments: \(args)")

        try Command.trySpawn(
            configureScript.path,
            currentDirectory: url.path,
            env: self.env,
            args
        )
    }

    override func make(fromURL url: URL) throws {
        let processorCount = ProcessInfo.processInfo.processorCount
        try Command.trySpawn(
            "/usr/bin/make",
            currentDirectory: url.path,
            [
                "-j\(processorCount)"
            ]
        )
    }

    override func install(fromURL url: URL, toURL: URL) throws {
        try Command.trySpawn(
            "/usr/bin/make",
            currentDirectory: url.path,
            [
                self.buildProperties.installCommand ?? "install"
            ]
        )
    }
}

class CMakeBuilder: Builder {

    override func setup() throws {
        try super.setup()
    }

    override func build() throws {
        print("Building package \(self.packageName) with CMake...")
        try super.build()
    }

    override func configure(architecture: String, inURL url: URL, buildOutputURL: URL) throws {

        var args = [
            "-DCMAKE_C_FLAGS=\(self.deploymentTarget) -fembed-bitcode",
            "-DCMAKE_INSTALL_PREFIX=\(buildOutputURL.path)",
            "-DCMAKE_OSX_SYSROOT=\(self.sysroot.path)",
            "-DCMAKE_OSX_ARCHITECTURES=\(architecture)",
            "-DCMAKE_PREFIX_PATH=\(self.buildRoot.path)",
            "-DPKG_CONFIG_USE_CMAKE_PREFIX_PATH=ON"
        ]
        if let packageArgs = self.buildProperties.buildArgs {
            args = args + packageArgs
        }
        if let packageArchSpecificArgs = self.buildProperties.buildArchSpecificArgs?[self.platformName]?[architecture] {
            args = args + packageArchSpecificArgs
        }

        args = applyEnvToArgs(args)

        // Repository url
        args = args + [self.sourceRoot.path]

        print("Running CMake with arguments: \(args)")

        try Command.trySpawn(
            "/usr/local/bin/cmake",
            currentDirectory: url.path,
            env: self.env,
            args
        )
    }

    override func make(fromURL url: URL) throws {
        let processorCount = ProcessInfo.processInfo.processorCount
        try Command.trySpawn(
            "/usr/bin/make",
            currentDirectory: url.path,
            [
                "-j\(processorCount)"
            ]
        )
    }

    override func install(fromURL url: URL, toURL: URL) throws {
        try Command.trySpawn(
            "/usr/bin/make",
            currentDirectory: url.path,
            [
                self.buildProperties.installCommand ?? "install"
            ]
        )
    }
}

class XcodeBuilder: Builder {

    override func configure(architecture: String, inURL url: URL, buildOutputURL: URL) throws {

        let environment = ProcessInfo.processInfo.environment

        let deploymentTarget: String
        if let deploymentTargetName = environment["DEPLOYMENT_TARGET_SETTING_NAME"], let value = environment[deploymentTargetName] {
            deploymentTarget = "\(deploymentTargetName)=\(value)"
        } else if let value = environment["IPHONEOS_DEPLOYMENT_TARGET"] {
            deploymentTarget = "IPHONEOS_DEPLOYMENT_TARGET=\(value)"
        } else {
            deploymentTarget = "IPHONEOS_DEPLOYMENT_TARGET=9.0"
        }
        var args = [
            "install",
            "-sdk", self.sysroot.path,
            "-arch", architecture,
            deploymentTarget,
            "OBJROOT=\(buildOutputURL.path)",
            "SYMROOT=\(buildOutputURL.path)",
            "DSTROOT=\(buildOutputURL.path)",
            "OTHER_LDFLAGS=-L\(self.buildRoot.path)/lib",
            "IBUILD_CURRENT_BUILD_ROOT=\(self.buildRoot.path)",
            "IBUILD_CURRENT_PACKAGE_ROOT=\(packageRoot.path)"
        ]
        if let packageArgs = self.buildProperties.buildArgs {
            args = args + packageArgs
        }
        if let packageArchSpecificArgs = self.buildProperties.buildArchSpecificArgs?[self.platformName]?[architecture] {
            args = args + packageArchSpecificArgs
        }
        try Command.trySpawn(
            "/usr/bin/xcodebuild",
            currentDirectory: self.sourceRoot.path,
            args
        )
    }

    override func install(fromURL url: URL, toURL: URL) throws {
        let libURL = toURL.appendingPathComponent("lib")
        let xcodeOutputURL = toURL.appendingPathComponent("Release-\(self.platformName)")

        try FileManager.default.createDirectory(atPath: libURL.path, withIntermediateDirectories: true, attributes: nil)

        for libraryName in self.buildProperties.outputs ?? [] {
            try Command.cp(from: xcodeOutputURL.appendingPathComponent(libraryName), to: libURL)
        }

        // Copy swiftmodule(s)
        let swiftmoduleURL = toURL.appendingPathComponent("swiftmodules")
        for path in try FileManager.default.contentsOfDirectory(at: xcodeOutputURL, includingPropertiesForKeys: nil, options: []) {
            if path.pathExtension == "swiftmodule" {
                try FileManager.default.createDirectory(atPath: swiftmoduleURL.path, withIntermediateDirectories: true, attributes: nil)
                try Command.cp(from: path, to: swiftmoduleURL.appendingPathComponent(path.lastPathComponent))
            }
        }
    }

    override func lipo(from architectureMap: [(architecture: String, url: URL)], toURL: URL) throws {
        if toURL.pathExtension == "framework" {
            // Special behavior for frameworks: 
            // - Copy framework from first architecture
            // - Lipo FrameworkName.framework/FrameworkName binary.
            // - Copy swiftmodules from FrameworkName.framework/Modules/FrameworkName.swiftmodule
            
            if let firstArchitecture = architectureMap.first?.url {
                try Command.cp(from: firstArchitecture, to: toURL)
            }

            let binaryName = toURL.deletingPathExtension().lastPathComponent
            let binaryArchitectureMap = architectureMap.map { (architecture: $0.architecture, url: $0.url.appendingPathComponent(binaryName)) }
            let binaryToURL = toURL.appendingPathComponent(binaryName)
            try super.lipo(from: binaryArchitectureMap, toURL: binaryToURL)

            for arch in architectureMap {
                try Command.cp(from: arch.url.appendingPathComponent("Modules").appendingPathComponent("\(binaryName).swiftmodule"), to: toURL.appendingPathComponent("Modules"))
            }
        } else {
            // Default behavior
            try super.lipo(from: architectureMap, toURL: toURL)
        }
    }
}