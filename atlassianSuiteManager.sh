#!/bin/bash

#
#    Copyright 2012 Stuart Ryan
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

clear


########################################
#Test system for required Binaries     #
########################################
checkRequiredBinaries(){
BINARIES="wget rpm zip unzip tar perl"
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
MODULES="LWP::Simple JSON Data::Dumper Config::Simple Crypt::SSLeay"
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
#Test for script running as root       #
########################################
checkForRootAccess(){

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root" 1>&2
   exit 1
fi
}


checkForRootAccess
checkRequiredBinaries
checkPerlModules
perl perl/AtlassianSuiteManager.pl

exit 0