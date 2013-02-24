#!/bin/bash

#
#    Copyright 2012-2013 Stuart Ryan
#
#    Application Name: AtlassianSuiteManager
#    Application URI: http://technicalnotebook.com/wiki/display/ATLASSIANMGR/Atlassian+Suite+Manager+Scripts+Home
#    Version: 0.1
#    Author: Stuart Ryan
#    Author URI: http://stuartryan.com
#
#    ###########################################################################################
#    I would like to thank Atlassian for providing me with complimentary OpenSource licenses to
#    CROWD, JIRA, Fisheye, Confluence, Greenhopper and Team Calendars for Confluence
#    Without them keeping track of, and distributing my scripts and knowledge would not be as
#    easy as it has been. So THANK YOU ATLASSIAN, I am very grateful.
#    ###########################################################################################
#
#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.

#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.

#    You should have received a copy of the GNU General Public License
#    along with this program.  If not, see <http://www.gnu.org/licenses/>.

SCRIPTVERSION="0.1"
LATESTDOWNLOADURL=http://technicalnotebook.com/asmGitPublicRepo/LATEST
clear


########################################
#Test system for required Binaries     #
########################################
checkRequiredBinaries(){
BINARIES="wget zip unzip tar perl"
BINARIESCHECK=""

for i in $BINARIES
do
   type -P $i &>/dev/null  && continue  || { echo "$i command not found."; BINARIESCHECK="FAIL"; }
done

if [[ $BINARIESCHECK == "FAIL" ]] ; then
   echo ""
   echo "Some required components are missing therfore this script cannot be run. Please install the aforementioned"
   echo "components and then run this script again."
   echo ""
   echo ""
   exit 1
fi

}

########################################
#Test system for required PERL Modules #
########################################
checkPerlModules(){
MODULES="LWP::Simple JSON Data::Dumper Config::Simple Crypt::SSLeay URI XML::Twig POSIX File::Copy File::Copy::Recursive Archive::Extract File::Path File::Find FindBin Socket Getopt::Long Log::Log4perl Archive::Tar Archive::Zip Filesys::DfPortable"
BINARIESCHECK=""

for i in $MODULES
do
   perl -e "use $i" &>/dev/null  && continue  || { echo "$i PERL module not found."; BINARIESCHECK="FAIL"; }
done

if [[ $BINARIESCHECK == "FAIL" ]] ; then
   echo ""
   echo "Some PERL modules are missing therfore this script cannot be run. Please install the aforementioned"
   echo "modules and then run this script again."
   echo ""
   echo ""
   exit 1
fi

}

########################################
#Check for script updates              #
########################################
checkforUpdate(){


for i in $MODULES
do
   perl -e "use $i" &>/dev/null  && continue  || { echo "$i PERL module not found."; BINARIESCHECK="FAIL"; }
done

if [[ $BINARIESCHECK == "FAIL" ]] ; then
   echo ""
   echo "Some PERL modules are missing therfore this script cannot be run. Please install the aforementioned"
   echo "modules and then run this script again."
   echo ""
   echo ""
   exit 1
fi

}

########################################
#Download new copy of LATEST file      #
########################################
downloadLatestFile(){
	mv LATEST .LATEST.OLD

	if ! wget --quiet $LATESTDOWNLOADURL ; then
    	mv .LATEST.OLD LATEST
	fi
}

########################################
#Process the LATEST file for updates   #
########################################
processLatestVersionFile(){
	source LATEST
	echo ${downloadURL[0]}
	#if [[ $test =~ ^test[A-Za-z0-9]+\.([0-9]+)\.out$ ]]; then
    #  echo ${BASH_REMATCH[1]}
    #fi
}





########################################
#Test for script running as root       #
########################################
checkForRootAccess(){

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root" 1>&2
   exit 1
fi
}

#for arg in "$@"
#do
#ARGS="$ARGS $arg"
#done

checkForRootAccess
checkRequiredBinaries

#import custom includes if the file exists
if [ -f "shellScriptIncludes.inc" ]; then
	source shellScriptIncludes.inc
	if [ ! -z "$VAR" ]; then
	echo "test"
	fi
fi

echo "Please wait, checking for updates..."

downloadLatestFile
processLatestVersionFile

checkPerlModules
perl perl/AtlassianSuiteManager.pl $ARGS

exit 0