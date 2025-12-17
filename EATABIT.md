## Eatabit info

# Branches other than master are synced to the original RPi-Distro/pi-gen repo

# use the amd64 branch

# To update the amd64 branch from ORIGINAL repo
- git checkout amd64
- git branch -u upstream/amd64 amd64
- git pull

# To push changes on amd64 to eatabit fork
- git push origin

# To build an image
- ./build.sh -c config