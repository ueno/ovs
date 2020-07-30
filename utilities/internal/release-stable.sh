#!/bin/bash

# Copyright (c) 2021-2024 Ilya Maximets <i.maximets@ovn.org>.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at:
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Notes:
#
# - This script clones and works with ovs repository in /tmp.
#   So, /tmp/ovs will be removed by 'make-patches' command and re-created.
#
# - All stable branches should be previously correctly tagged since this
#   script will find the last tag on each branch and create release patches and
#   new tags for version 'last_tag + 1'.
#
# - By default this script will try to use $(pwd) as a reference to speed up
#   clone of the repository.  So, it's better to run from the top of the
#   existing openvswitch repository.  Alternatively, 'GIT_REFERENCE'
#   environment variable could be used.
#
# - Also this script will add all remotes, except origin, of the current git
#   tree to the new git tree in /tmp/ovs, so they could be used later for
#   'push-releases' command.  Might be useful for testing purposes before
#   pushing to origin.
#
# - Script will invoke 'vim' by defualt for last minute NEWS file updates.

set -x
set -o errexit

prepare_patches_for_minor_release()
{
    LAST_VERSION=$(git describe --abbrev=0 | cut -c 2-)

    LTS=$(grep '\w*LTS release is \([0-9]*\.[0-9]*\)\.x\.' \
                Documentation/faq/releases.rst \
            | sed 's/.*is \([0-9]*\.[0-9]*\)\.x\./\1/')

    if [ -z "$LAST_VERSION" ] ; then
        echo "Could not parse version.  Assuming major release."
        BRANCH=$(git rev-parse --abbrev-ref HEAD \
                 | sed 's/[a-z-]*\([0-9\.]*\)/\1/')
        LAST_VERSION="${BRANCH}.-1"
        MAJOR=yes
        if [ $# -eq 2 ] && [ "${1}" == '--lts' ] \
           && [ "${2}" != "${LTS}" ]; then
            LTS=${2}
            LTS_CHANGE=yes
        fi
    fi

    BRANCH=${LAST_VERSION%.*}
    RELEASE=${LAST_VERSION##*.}
    VERSION=${BRANCH}.$(($RELEASE + 1))
    NEXT_VERSION=${BRANCH}.$(($RELEASE + 2))

    echo "Preparing patches for version ${VERSION}"

    DATE=$(date +'%d %b %Y')
    DATETIME=$(date -R)

    N_PATCHES=2

    if [ -n "$LTS_CHANGE" ]; then
        echo "Creating a patch to update current LTS version."

        sed -i "s/\(\w*LTS release is\) [0-9]*\.[0-9]*\.x\./\1 ${LTS}.x./" \
            Documentation/faq/releases.rst
        MSG="With release of OVS v${VERSION},"
        MSG=${MSG}" according to our release process,\n"
        MSG=$MSG"${LTS}.x becomes a new LTS series."
        MSG=$(printf "${MSG}")
        git commit -a -s \
            -m "releases: Mark ${LTS} as a new LTS release." -m "${MSG}"
        N_PATCHES=3
    fi

    echo "Creating release date adjustment commit"

    sed -i "1 s/xx xxx xxxx/${DATE}/" NEWS
    [ -n "$MAJOR" ] || sed -i "3 i \   - Bug fixes" NEWS

    LINE=$(grep -n -m 1 ' \-\- Open vSwitch team' debian/changelog \
               | sed  's/\([0-9]*\).*/\1/')
    sed -i \
        "${LINE} c \ -- Open vSwitch team <dev@openvswitch.org>  ${DATETIME}" \
                                                  debian/changelog

    # Last-minute NEWS update.
    vim NEWS

    git commit -a -s -m "Set release date for ${VERSION}."

    echo "Creating next release preparation commit"

    VERSION_LINE="v${NEXT_VERSION} - xx xxx xxxx"
    printf -v DASH_LINE '%0.s-' $(seq 1 ${#VERSION_LINE})
    sed -i "1 i ${VERSION_LINE}\n${DASH_LINE}\n" NEWS

    sed -i "1 i openvswitch (${NEXT_VERSION}-1) unstable; urgency=low\n" \
                                                  debian/changelog
    sed -i "2 i \   [ Open vSwitch team ]"        debian/changelog
    sed -i "3 i \   * New upstream version\n"     debian/changelog
    sed -i "5 i \ -- Open vSwitch team <dev@openvswitch.org>  ${DATETIME}" \
                                                  debian/changelog

    sed -i \
      "s/AC_INIT(openvswitch, ${VERSION}/AC_INIT(openvswitch, ${NEXT_VERSION}/"\
      configure.ac

    git commit -a -s -m "Prepare for ${NEXT_VERSION}."

    echo "Formatting patches for email"
    mkdir -p patches/release-${VERSION}
    git format-patch -o patches/release-${VERSION}             \
                     --subject-prefix="PATCH branch-${BRANCH}" \
                     --cover-letter -${N_PATCHES}
    sed -i "s/\*\*\* SUBJECT HERE \*\*\*/Release patches for v${VERSION}./" \
        patches/release-${VERSION}/0000-cover-letter.patch
    sed -i "/\*\*\* BLURB HERE \*\*\*/d" \
        patches/release-${VERSION}/0000-cover-letter.patch
}

clone_and_set_remotes()
{
    rm -rf /tmp/ovs
    git clone --reference-if-able ${GIT_REFERENCE} --dissociate \
              https://github.com/openvswitch/ovs.git
    pushd ovs

    if [ -n "${remotes}" ]; then
        echo "${remotes}" | while read line ; do
            git remote add ${line}
        done
    fi
    popd
}

usage()
{
    set +x
    echo "Usage: ${0} command BRANCHES [extra-options]"
    echo "Commands:"
    echo "  make-patches   BRANCHES [--lts VER]     (create patch files)"
    echo "  send-emails    BRANCHES [extra options] (send patches)"
    echo "  add-commit-tag BRANCHES TAG             (add commit message tag)"
    echo "  tag-releases   BRANCHES                 (add git tags to commits)"
    echo "  push-releases  BRANCHES remote [extra]  (push to github)"
    echo "  pypi-upload    BRANCHES                 (upload releases to pypi)"
    echo "  update-website all                      (prepare website commit)"
    echo "  announce       BRANCHES [--major-prev VER] [extra options]"
    echo "                                          (send announce email)"
    echo
    echo "Ex.:"
    echo "  $ ${0} make-patches   '2.7 2.8'"
    echo "  $ ${0} send-emails    '2.7 2.8' --cc \"Name <email>\" --dry-run"
    echo "  $ ${0} add-commit-tag '2.7 2.8' 'Acked-by: Name <email>'"
    echo "  $ ${0} tag-releases   '2.7 2.8'"
    echo "  $ ${0} push-releases  '2.7 2.8' origin --dry-run"
    echo "  $ ${0} pypi-upload    '2.7 2.8'"
    echo "  $ ${0} update-website  all"
    echo "  $ ${0} announce       '2.7 2.8' --cc \"Name <email>\" --dry-run"
    echo
    echo "  For a major release with LTS version change:"
    echo "  $ ${0} make-patches   '3.0' --lts 2.17"
    echo
    echo "  For the announce of the a major release:"
    echo "  $ ${0} announce       '3.0' --major-prev 2.17 [--dry-run]"
    echo
}

[ "$#" -gt 1 ] || (usage && exit 1)

command=${1}
shift
BRANCHES="${1}"
shift

GIT_REFERENCE=${GIT_REFERENCE:-$(pwd)}

remotes=""
if git rev-parse --git-dir > /dev/null 2>&1; then
    remotes=$(git remote -v | grep fetch | grep -v origin | sed 's/ (.*)//')
fi

pushd /tmp

case $command in
make-patches)
    clone_and_set_remotes
    pushd ovs
    for BR in ${BRANCHES}; do
        git checkout origin/branch-${BR} -b release-branch-${BR}
        git pull --rebase
        prepare_patches_for_minor_release "${@}"
    done
    popd
    ;;
send-emails)
    pushd ovs
    git checkout main
    for BR in ${BRANCHES}; do
        ./utilities/checkpatch.py patches/release-${BR}*/*
        git send-email --to 'ovs-dev@openvswitch.org' "${@}" \
                       patches/release-${BR}*/*
    done
    popd
    ;;
add-commit-tag)
    pushd ovs
    git reset --hard
    for BR in ${BRANCHES}; do
        N=$(ls patches/release-${BR}*/000[1-3]* | wc -l)
        sed -i "/Signed-off-by.*/i ${@}" patches/release-${BR}*/000[1-${N}]*
        git checkout release-branch-${BR}
        git reset --hard HEAD~${N}
        git am patches/release-${BR}*/000[1-${N}]*
        git pull --rebase
    done
    popd
    ;;
tag-releases)
    pushd ovs
    for BR in ${BRANCHES}; do
        git checkout release-branch-${BR}
        git pull --rebase
        version=$(git log HEAD^ -1 --pretty="%s" | \
                  sed 's/.* \([0-9]*\.[0-9]*\.[0-9]*\)\./\1/')
        git tag -s v${version} -m "Open vSwitch version ${version}." HEAD^
    done
    popd
    ;;
push-releases)
    pushd ovs
    for BR in ${BRANCHES}; do
        git checkout release-branch-${BR}
        git push "${@}" HEAD:branch-${BR} --follow-tags
    done
    popd
    ;;
pypi-upload)
    pushd ovs
    for BR in ${BRANCHES}; do
        git reset --hard
        git checkout release-branch-${BR}
        git checkout $(git describe --abbrev=0)
        ./boot.sh && ./configure && make pypi-upload
        make distclean
    done
    popd
    ;;
update-website)
    rm -rf /tmp/openvswitch.github.io
    git clone https://github.com/openvswitch/openvswitch.github.io.git

    [ ! -d ./ovs ] && clone_and_set_remotes
    pushd ovs
    git fetch
    git tag | grep -E 'v[2-9]\.[0-9]*\.[0-9]*$' | cut -c 2- | sort -V -r | \
              sed '/2.5.0/q' | sed -e 's/^/- /' \
              >> ../openvswitch.github.io/_data/releases.yml
    popd

    pushd openvswitch.github.io
    sort -V -u -r _data/releases.yml -o _data/releases.yml
    missed_versions=$(git diff | grep '^+- ' | cut -c 4- | tac)
    popd

    pushd ovs
    for version in ${missed_versions}; do
        git reset --hard
        git checkout v${version}
        ./boot.sh && ./configure && make dist-gzip
        make distclean
        cp openvswitch-${version}* ../openvswitch.github.io/releases/
        cp NEWS ../openvswitch.github.io/releases/NEWS-${version}
        cp NEWS ../openvswitch.github.io/releases/NEWS-${version}.txt
    done

    LTS=$(git grep '\w*LTS release is \([0-9]*\.[0-9]*\)\.x\.' \
                origin/main:Documentation/faq/releases.rst \
            | sed 's/.*is \([0-9]*\.[0-9]*\)\.x\./\1/')

    latest=$(git tag | sort -V -r | head -1 | cut -c 2-)
    latest_lts=$(git tag | grep "v${LTS}\." | sort -V -r | head -1 | cut -c 2-)
    popd

    pushd openvswitch.github.io
    sed -i "/Current release/{s/[0-9]*\.[0-9]*\.[0-9]*/${latest}/g}" \
           _includes/side-widgets.html
    sed -i "/Current LTS/{s/[0-9]*\.[0-9]*\.[0-9]*/${latest_lts}/g}" \
           _includes/side-widgets.html

    sed -i "/The most recent.*current/{n;s/-[0-9\.]*.tar/-${latest}.tar/g}" \
           download/index.html
    sed -i "/The most recent.*LTS/{n;s/-[0-9\.]*.tar/-${latest_lts}.tar/g}" \
           download/index.html

    git add releases/*
    if ! git diff --cached --exit-code > /dev/null; then
        releases=$(echo "${missed_versions}" | tac | head -4 | tr '\n' ' ')
        all_releases=$(echo "${missed_versions}" | sed -e 's/^/  - /')
        git commit -s -a -m "Add new and missing releases: ${releases} etc." \
                         -m "Added tarballs and NEWS for:" -m "${all_releases}"
    fi
    popd

    echo "Updating dist-docs."

    pushd openvswitch.github.io
    current=$(grep -oh 'Open vSwitch [0-9\.]*' ./support/dist-docs/index.html \
                | head -1 | cut -d' ' -f 3)
    popd
    pushd ovs
    latest=$(git tag | sort -V -r | head -1)
    popd

    if [ "v${current}" == "${latest}" ]; then
        echo "Man pages are up to date."
    else
        pushd openvswitch.github.io
        rm -rf ./support/dist-docs/*
        popd

        pushd ovs
        git reset --hard
        git checkout ${latest}
        rm -rf ./dist-docs
        ./boot.sh && ./configure && make dist-docs
        cp -r dist-docs ../openvswitch.github.io/support/
        make distclean
        popd

        pushd openvswitch.github.io
        git add support/dist-docs
        git commit -s -a -m "support: Update man pages to ${latest}."
        popd
    fi
    ;;
announce)
    pushd ovs
    subject=""
    echo "From: $(git config user.name) <$(git config user.email)>" > mbox
    echo "" >> mbox

    BRANCHES=$(echo $BRANCHES | tr ' ' '\n' | tac | tr '\n' ' ' \
                | sed 's/[[:space:]]*$//')
    MAJOR=false

    if [ $# -ge 2 ] && [ "${1}" == '--major-prev' ]; then
        MAJOR=true
        echo "The Open vSwitch team is pleased to announce the release" \
             "of Open vSwitch ${BRANCHES}.0:" >> mbox
    else
        echo "The Open vSwitch team is pleased to announce a number" \
             "of bug fix releases:" >> mbox
        echo "" >> mbox
        echo "  Latest stable:" >> mbox
        echo "      https://www.openvswitch.org/releases/<...>" >> mbox
        echo "" >> mbox
        echo "  Current LTS series:" >> mbox
        echo "      https://www.openvswitch.org/releases/<...>" >> mbox
        echo "" >> mbox
        echo "  Other:" >> mbox
        echo "      https://www.openvswitch.org/releases/<...>" >> mbox
        echo "      https://www.openvswitch.org/releases/<...>" >> mbox
        echo "" >> mbox
        echo "" >> mbox
        echo "Among other bug fixes and improvements," \
             "these releases are/include ..." >> mbox
        echo "" >> mbox
    fi
    echo "" >> mbox

    for BR in ${BRANCHES}; do
        git reset --hard
        git checkout release-branch-${BR}
        git pull --rebase
        tag=$(git describe --abbrev=0 | cut -c 2-)
        subject="${subject}, ${tag}"
        archive="openvswitch-${tag}.tar.gz"
        if [ "${MAJOR}" == "true" ]; then
            sp="  "
        else
            sp="      "
        fi
        echo "${sp}https://www.openvswitch.org/releases/${archive}" >> mbox
    done
    echo "" >> mbox

    if [ $# -ge 2 ] && [ "${1}" == '--major-prev' ]; then
        prev=${2}
        shift; shift
        br="${BRANCHES}"
        tag="${BRANCHES}.0"

        echo "A few other feature highlights of ${tag} include:" >> mbox
        echo "" >> mbox
        echo "  ----  REMOVE MOST OF THE NEWS ----" >> mbox
        echo "" >> mbox
        git show origin/branch-${br}:NEWS \
            | awk "/v${tag}/{flag=1} /v${prev}.0/{flag=0} flag" >> mbox

        echo "   - And many others.  See the full change log here:" >> mbox
        news="NEWS-${tag}.txt"
        echo "       https://www.openvswitch.org/releases/${news}" >> mbox
        echo "" >> mbox
        echo "" >> mbox

        new=$(git log --grep="Set release date for ${tag}." \
                      --pretty=%H origin/main)
        old=$(git log --grep="Set release date for ${prev}.0." \
                      --pretty=%H origin/main)
        commits=$(git log --oneline ${old}..${new} | wc -l)
        authors=$(git shortlog -s ${old}..${new} | wc -l)
        domains=$(git log --format="%ae" ${old}..${new} \
                    | sed 's/.*@\(.*\)/\1/' | sort | uniq -c | wc -l)

        echo "This release cycle includes ${commits} commits from" \
             "${authors} contributors from ${domains} domains:" >> mbox
        echo "" >> mbox
        # List all the domains.
        git log --format="%ae" ${old}..${new} | sed 's/.*@\(.*\)/\1/' \
            | sort | uniq -c | cut -c 9- | sed 's/\(.*\)$/\1,/' | tr '\n' ' ' \
            | rev | cut -c 3- | rev | sed 's/\./\\\./g' \
            | sed 's/\(.*\), \(.*\)/\1 and \2./' | fold -sw 78 \
            | sed 's/\(.*\)/  \1/' | sed 's/[[:space:]]*$//' >> mbox
        echo "" >> mbox

        git shortlog -s ${old} | cut -f 2 > ${old}.authors
        git shortlog -s ${new} | cut -f 2 > ${new}.authors
        new_authors=$(diff -u ${old}.authors ${new}.authors \
                        | grep '^+[^+]' | cut -c 2- | wc -l)
        echo "Including ${new_authors} new contributors" \
             "(authors and co-authors).  Welcome to:" >> mbox
        echo "" >> mbox

        # List new authors.
        diff -u ${old}.authors ${new}.authors | grep '^+[^+]' | cut -c 2- \
            | tr ' ' '_' | sed 's/\(.*\)$/\1,/' | tr '\n' ' ' \
            | rev | cut -c 3- | rev | sed 's/\(.*\), \(.*\)/\1 and \2./' \
            | fold -sw 78 | sed 's/\(.*\)/  \1/' | tr '_' ' ' \
            | sed 's/[[:space:]]*$//' >> mbox
        echo "" >> mbox
        echo "" >> mbox

        echo "Thanks, everyone!  Enjoy!" >> mbox
    fi

    echo "" >> mbox
    echo "--The Open vSwitch Team" >> mbox
    echo "" >> mbox
    echo "--------------------"
    echo "Open vSwitch is a production quality, multilayer open source"       \
         "virtual switch.  It is designed to enable massive network"          \
         "automation through programmatic extension, while still supporting"  \
         "standard management interfaces.  Open vSwitch can operate both as"  \
         "a soft switch running within the hypervisor, and as the control"    \
         "stack for switching silicon.  It has been ported to multiple"       \
         "virtualization platforms and switching chipsets."                   \
           | fold -sw 81 | sed -e 's/[[:space:]]*$//' >> mbox

    subject=$(echo "$subject" | sed 's/^,\(.*\)/\1/' | sed 's/\(.*\),/\1 and/')
    if [[ $subject == *"and"* ]]; then
        verb=are
    else
        verb=is
    fi
    if [ "${MAJOR}" == "true" ]; then
        sed -i "2 i Subject: Open vSwitch${subject} is now Available!\n" mbox
    else
        sed -i "2 i Subject: Open vSwitch${subject} ${verb} available.\n" mbox
    fi
    git send-email --to 'ovs-announce@openvswitch.org' mbox --annotate "${@}"
    rm -rf mbox
    popd
    ;;
*)
    usage
    ;;
esac
