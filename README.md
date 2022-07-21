# Install via CPAN

Reference: https://mogilefs.github.io/mogilefs-docs/InstallHowTo.html

# Build

`docker build -f Dockerfile -t mogile_fs_server .`

# Usage

The docker image will already build the debian package. All you need to do is install it with the proper mogile configuration. The debian package can be found at the root directory `cd /`

You can push the built image to our gcr repo and then include it in your dockerfile.