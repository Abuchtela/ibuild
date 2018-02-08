# ibuild

`ibuild` is a build system for iOS libraries that are built without using build systems like CMake or Make.

A typical workflow for using `ibuild` is as follows:
1. Create a `build.plist` file in the root of your repo.
2. Add a list of dependencies to build to the `build.plist`.
3. Add an "External Build System" target to your Xcode project, pointing to the `ibuild` binary.

Now, when you build with Xcode, `ibuild` will ensure that all of the dependencies in your `build.plist` are built.

# Packages you can depend on
If a package has defined a `build.plist` in its root, it can be depended on simply by adding it to the `dependencies` array in your `build.plist`. Some packages include:
- [libgit2-ios](https://github.com/IMcD23/libgit2-ios)
- [openssl-ios](https://github.com/IMcD23/openssl-ios)
- [libssh2-ios](https://github.com/IMcD23/libssh2-ios)
- [libcurl-ios](https://github.com/IMcD23/libcurl-ios)

If you want to build another package that doesn't have a `build.plist`, you must create one for the project. Follow the example of the projects above.
You can depend on packages using git, or depend on a package at a local path.

# build.plist files

Below is the schema for a `build.plist` file. A question mark represents an optional property.

```
{
    # Display name of the package
    name: String

    build?: {

        # The location of the source code to build
        library?: {
            # Type of the location.
            # Values: github / git / local
            type: String

            # Required for GitHub and Local types.
            # Should be either "username/repo" or "path/to/package", respectively
            path?: String

            # Required for GitHub or Git types.
            # The name of the branch to check out.
            branch?: String

            # Required for Git type.
            # URL to pass to git clone.
            url?: String
        }

        # The build sytem to use when building.
        # Values: none / cmake / make / xcode / custom
        buildSystem: String

        # Arguments to pass when configuring / building
        buildArgs?: [String]

        # Additional arguments to pass, that depend on
        # platform and architecture
        buildArchSpecificArgs?: {
            <platform>: {
                <arch>: [String]
            }
        }

        # When building a `make` project, this command will
        # replace the `install` in `make install`.
        # Has no effect with other build systems
        installCommand?: String

        # Names of the libraries that are generated by
        # the build of the `library` property
        outputs?: [String]

        # Paths of source files in this package to also copy to final output directory.
        auxiliaryFiles?: {
            "package/path": "install/path"
        }

        # When the build system is "custom", these properties determine which commands to run.
        customProperties?: {
            configure: String
            make: String
            install: String
            env?: {
                "key": "value"
            }
        }
    }

    # Dependencies of this package
    dependencies: [
        {
            # Type of the location.
            # Values: github / git / local
            type: String

            # Required for GitHub and Local types.
            # Should be either "username/repo" or "path/to/package", respectively
            path?: String

            # Required for GitHub or Git types.
            # The name of the branch to check out.
            branch?: String

            # Required for Git type.
            # URL to pass to git clone.
            url?: String
        }
    ]
}
```