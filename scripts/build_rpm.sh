#!/bin/bash -xe

set -o pipefail

shift   # First parameter is TARGET, not needed here

source $(dirname $0)/common-functions

exec &> >(tee "${OUTPUT_DIRECTORY}/rpmbuild.log") 2>&1
set -x

for FILE in {test-,}requirements.txt
do
    if [ -f ${FILE} ]
    then
        sed -i "s/; *python_version.*[!=<>]=\?.*//g" ${FILE}
        sed -i "s/; *sys_platform.*[!=<>]=\?.*//g" ${FILE}
    fi
done

cleanup_sdist

MOCKOPTS="-v -r ${DATA_DIR}/${MOCK_CONFIG} --resultdir $OUTPUT_DIRECTORY"

# Cleanup mock directory and copy sources there, so we can run python setup.py
# inside the buildroot
/usr/bin/mock $MOCKOPTS --clean
/usr/bin/mock $MOCKOPTS --init
# A simple mock --copyin should be enough, but it does not handle symlinks properly
MOCKDIR=$(/usr/bin/mock -r ${DATA_DIR}/${MOCK_CONFIG} -p)

# handle python packages (some puppet modules are carrying a setup.py too)
if [ -r setup.py -a ! -r metadata.json ]; then
    SOURCETYPE='tarball'
    mkdir ${MOCKDIR}/var/tmp/pkgsrc
    cp -pr . ${MOCKDIR}/var/tmp/pkgsrc

    # setup.py outputs warning (to stdout) in some cases (python-posix_ipc)
    # so only look at the last line for version
    setversionandrelease $(/usr/bin/mock -q -r ${DATA_DIR}/${MOCK_CONFIG} --chroot "cd /var/tmp/pkgsrc && rm -rf *.egg-info && python setup.py --version"| tail -n 1) \
                         $(/usr/bin/mock -q -r ${DATA_DIR}/${MOCK_CONFIG} --chroot "cd /var/tmp/pkgsrc && git log --abbrev=7 -n1 --format=format:%h")

    /usr/bin/mock $MOCKOPTS --chroot "cd /var/tmp/pkgsrc && python setup.py sdist"
    /usr/bin/mock $MOCKOPTS --copyout /var/tmp/pkgsrc/dist ./dist
elif [ -r *.gemspec ]; then
    SOURCETYPE='gem'
    GEMSPEC=$(ls -l | grep gemspec | awk '{print $9}')
    PROJECT=$(basename $GEMSPEC .gemspec)
    VERSION=$(ruby -e "require 'rubygems'; spec = Gem::Specification::load('$GEMSPEC'); puts spec.version")
    mkdir ${MOCKDIR}/var/tmp/pkgsrc
    cp -pr . ${MOCKDIR}/var/tmp/pkgsrc
    /usr/bin/mock $MOCKOPTS --chroot "cd /var/tmp/pkgsrc && gem build $GEMSPEC"
    /usr/bin/mock $MOCKOPTS --copyout /var/tmp/pkgsrc/$PROJECT-$VERSION.gem ./$PROJECT-$VERSION.gem
    setversionandrelease "$VERSION" $(git log --abbrev=7 -n1 --format=format:%h)
else
    SOURCETYPE='tarball'
    # For Puppet modules, check the version in metadata.json (preferred) or Modulefile
    if [ -r metadata.json ]; then
        version=$(python -c "import json; print json.loads(open('metadata.json').read(-1))['version']")
    elif [ -r Modulefile ]; then
        version=$(grep version Modulefile | sed "s@version *'\(.*\)'@\1@")
    else
        version=""
    fi

    # Not able to discover version, use git tags
    if [ -z "$version" ]; then
        version="$(git describe --abbrev=0 --tags 2> /dev/null|sed 's/^[vVrR]//' || :)"
    fi

    # One final attempt for openstack/rpm-packaging
    if [ -z "$version" ]; then
        pushd ${DISTGIT_DIR}
        if git remote -v | grep openstack/rpm-packaging; then
            version=$(grep Version *.spec | awk '{print $2}' | head -n 1)
        fi
        popd
    fi

    # We got a version. Check if we need to increase a .Z release due to post-tag commits
    if [ -n "$version" ]; then
        post_version=$(git describe --tags|sed 's/^[vVrR]//' || :)
        current_tag=$(git describe --abbrev=0 --tags|sed 's/^[vVrR]//' || :)
        if [ "$post_version" != "$current_tag" ]; then
            # We have a potential post-version. Only applies if
            # version == current_tag without -rc inside
            if [[ "$version" = "$current_tag" && ! "$version" =~ "-rc" ]]; then
                # Now increase the .Z release
                version=$(awk -F. '{ for (i=1;i<NF;i++) printf $i"."; print $NF+1 }' <<< $version)
            fi
        fi
    fi

    # fallback to an arbitrary version
    if [ -z "$version" ]; then
        version=0.0.1
    fi
    setversionandrelease "$version" $(git log --abbrev=7 -n1 --format=format:%h)
    if [ -r metadata.json ]; then
        # Detect if this is am OpenStack puppet module
        TARBALLS_OPS=$(egrep -c -e "^Source0.*tarballs.openstack.org" -e "^Source0.*github.com\/openstack" -e "^Source0.*git.openstack.org\/openstack" ${DISTGIT_DIR}/*spec||true)
        echo $TARBALLS_OPS
        # We know OpenStack puppet modules have a common style for metadata.json
        if [ $TARBALLS_OPS -ne 0 ]; then
            TARNAME=$(python -c "import json; print json.loads(open('metadata.json').read(-1))['name']")
        else
            TARNAME=$(git remote -v|head -1|awk '{print $2;}'|sed 's@.*/@@;s@\.git$@@')
        fi
    elif [ -r Modulefile ]; then
        TARNAME=$(git remote -v|head -1|awk '{print $2;}'|sed 's@.*/@@;s@\.git$@@')
    elif [ -r Kconfig -a -r Kbuild ]; then
        TARNAME=linux
    else
        TARNAME=${PROJECT_NAME}
    fi
    tar zcvf ../$VERSION.tar.gz --exclude=.git --transform="s@${PWD#/}@${TARNAME}-${version}@" --show-transformed-names $PWD
    mkdir -p dist
    mv ../$VERSION.tar.gz dist/
fi

if [ "$SOURCETYPE" == 'gem' ]; then
    SOURCE=$(ls -l | grep '.gem$' | awk '{print $9}')
    SOURCEEXT='.gem'
    SOURCEPATH=$SOURCE
else
    SOURCE=$(ls dist | grep '.tar.gz')
    SOURCEEXT='.tar.gz'
    SOURCEPATH="dist/$SOURCE"
fi
SOURCEWITHREL=$(basename $SOURCE $SOURCEEXT)-$RELEASE$SOURCEEXT
mv $SOURCEPATH ${TOP_DIR}/SOURCES/$SOURCEWITHREL

cd ${DISTGIT_DIR}
cp -a * ${TOP_DIR}/SOURCES/
cp *.spec ${TOP_DIR}/SPECS/
cd ${TOP_DIR}/SPECS/

sed -i -e "1i%define upstream_version $UPSTREAMVERSION\\" *.spec
sed -i -e "1i%global dlrn 1\\" *.spec
sed -i -e "1i%global dlrn_nvr $(basename $SOURCEWITHREL $SOURCEEXT)\\" *.spec
sed -i -e "s/UPSTREAMVERSION/$UPSTREAMVERSION/g" *.spec
VERSION=${VERSION/-/.}
sed -i -e "s/Version:.*/Version: $VERSION/g" *.spec
sed -i -e "s/Release:.*/Release: $RELEASE%{?dist}/g" *.spec
sed -i -e "s/^\(Source\|Source0\):.*/\1: $SOURCEWITHREL/" *.spec
sed -i -e '/^%changelog.*/q' *.spec
cat *.spec
spectool -g -C ${TOP_DIR}/SOURCES *.spec
/usr/bin/mock --buildsrpm ${MOCKOPTS} --spec *.spec --sources=${TOP_DIR}/SOURCES

if [ -n "$COPR_ID" ]; then
    set +e
    copr build $COPR_ID ${OUTPUT_DIRECTORY}/*.src.rpm >& $OUTPUT_DIRECTORY/copr.log
    ret=$?
    set -e
    if [ $ret -eq 0 ]; then
        touch $OUTPUT_DIRECTORY/installed
    fi
    buildid=$(sed -n 's/Created builds: //p' < $OUTPUT_DIRECTORY/copr.log)
    if [ -z "$buildid" ]; then
        echo "Unable to find copr build id" 1>&2
        exit 1
    fi
    mkdir -p $OUTPUT_DIRECTORY/$buildid
    copr download-build -d $OUTPUT_DIRECTORY/$buildid $buildid
    mv -f $OUTPUT_DIRECTORY/$buildid/*/* $OUTPUT_DIRECTORY
    rm -rf $OUTPUT_DIRECTORY/$buildid
    rm -f $OUTPUT_DIRECTORY/index.html
else
    set +e
    if [ -n "${ADDITIONAL_MOCK_OPTIONS}" ]; then
        /usr/bin/mock ${MOCKOPTS} "${ADDITIONAL_MOCK_OPTIONS}" --postinstall --rebuild ${OUTPUT_DIRECTORY}/*.src.rpm 2>&1 | tee $OUTPUT_DIRECTORY/mock.log
    else
        /usr/bin/mock ${MOCKOPTS} --postinstall --rebuild ${OUTPUT_DIRECTORY}/*.src.rpm 2>&1 | tee $OUTPUT_DIRECTORY/mock.log
    fi
    ret=$?
    set -e

    if [ $ret = 0 ]; then
        if ! grep -F 'WARNING: Failed install built packages' $OUTPUT_DIRECTORY/mock.log; then
            touch $OUTPUT_DIRECTORY/installed
            ret=0
        else
            ret=1
        fi
    fi
fi

# We want to ignore any error in restorecon
set +e
if [ $(which restorecon) ]; then
    restorecon -Rv $OUTPUT_DIRECTORY
fi
set -e

exit $ret
