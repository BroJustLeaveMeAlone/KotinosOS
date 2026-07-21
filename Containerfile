# Base pinned to Fedora 44, the current stable release.
#
# Do not use :latest, and do not assume the highest tag number is stable --
# tag 45 is byte-identical to rawhide. Re-verify manifest digests before
# bumping to a new release.
FROM quay.io/fedora/fedora-bootc:44

# Identifies which build a running system came from. Milestone 1 proves
# rollback by booting v1, upgrading to v2, rolling back, and reading this
# file at each step to confirm which deployment is active.
ARG BUILD_ID=dev

RUN printf 'NAME="KotinosOS"\nID=kotinos\nBUILD_ID="%s"\nBASE="fedora-bootc:44"\n' "${BUILD_ID}" \
      > /usr/lib/kotinos-release

# Fails the build if the result is not a valid bootc image.
RUN bootc container lint
