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
#Set Up Variables                      #
########################################


########################################
#Test system for required Binaries     #
########################################
checkRequiredBinaries(){
BINARIES="wget rpm zip unzip tar"
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
#Test for script running as root       #
########################################
checkForRootAccess(){
BINARIES="wget rpm zip unzip tar"
BINARIESCHECK=""

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root" 1>&2
   exit 1
fi
}

if [[ $1 == "--someinput" ]] ; then
   echo "Placeholder for testing input parameters "
else
########################################
#Display Install Menu                  #
########################################
   AUTOMODE="none"
   LOG=$INSTALLLOG
   
   LOOP=1
   while [ $LOOP == "1" ]
   do
      clear
      echo "Welcome to the Atlassian Suite Manager Script"
      echo ""
      echo ""
      echo "AtlassianSuiteManager Copyright (C) 2012  Stuart Ryan"
      echo "This program comes with ABSOLUTELY NO WARRANTY;"
      echo "This is free software, and you are welcome to redistribute it"
      echo "under certain conditions; read the COPYING file included for details."
#      if [ $SCRIPTUPDATE -eq 1 ] ; then
#         echo ""
#         echo ""
#         echo "*******************************************************************"
#         echo "*             Please be aware this script is out of date          *"
#         echo "*               Please obtain the latest version from:            *"
#         echo "*    *"
#         echo "*******************************************************************"
#      fi
      echo ""
      echo ""
      echo "Please select from the following options:"
      echo "1. Menu Item Example"
      echo "Q. Quit"
      echo ""
      echo ""

      echo "Enter the number/letter of your selection then press enter"

      read -e MODE
      echo "MODE SELECTED IS $MODE" >> $INSTALLEDDIR/$LOG
      ########################################
      #       Menu - Option 1    #
      ########################################
      if [ $MODE == "1" ] ; then
         echo "mode 1"
      ##############################################
      #  Menu - Option 2  #
      ##############################################
      elif [ $MODE == "2" ] ; then
         echo "mode 12"
      ##############################################
      #   Menu - Quit and/or detect invalid input  #
      ##############################################
      elif [ $MODE == "q" ] || [ $MODE == "Q" ] ; then
         LOOP=0
         exit 0
         else
         echo "\""$MODE"\" is not a valid selection please press Enter to continue and try again"
         read -e NULLINPUT
      fi
   done
fi
exit 0