#!/bin/bash -e

function errcho() {
    echo "$@" 1>&2
}

if [[ -z "$JENKINS_HOME" ]]; then
    errcho "Missing JENKINS_HOME environment variable"
    exit 1
fi

mkdir -p "$JENKINS_HOME"
JENKINS_HOME=$(readlink -f "$JENKINS_HOME")

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT=$DIR/../..

cd $REPO_ROOT
git submodule update --init --recursive

mkdir -p $JENKINS_HOME/hottest
cd $JENKINS_HOME/hottest
for f in $(find $REPO_ROOT/scripts/jenkins-home/ -type f); do
    ln -sf $f;
done
rm -f $JENKINS_HOME/hottest/README $JENKINS_HOME/hottest/hush_shell.py

$REPO_ROOT/gitmodules/serio/serio --create-links --link-path=$REPO_ROOT/gitmodules/serio
cd $JENKINS_HOME

cat << INFO
run jenkins with:

 JENKINS_HOME=$JENKINS_HOME java -jar jenkins.war --httpPort=8080

if you don't have jenkins.war:

 wget http://mirrors.jenkins.io/war-stable/latest/jenkins.war

Install the Jenkins instance with the recommended set of plugins only. Follow
the Jenkins install instructions.

INFO
