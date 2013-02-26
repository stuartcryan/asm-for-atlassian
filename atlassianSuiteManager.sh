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
INSTALLDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

echo $INSTALLDIR


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
	cd $INSTALLDIR
	mv LATEST .LATEST.OLD > /dev/null 2&>1

	if ! wget --quiet $LATESTDOWNLOADURL ; then
    	mv .LATEST.OLD LATEST
	fi
}

compareTwoVersions(){
	
    #setUpCurrentVersion
    if [[ $1 =~ ^([0-9]*)\.([0-9]*)\.?([0-9]*?)$ ]]; then
   		CURRMAJORVERSION=${BASH_REMATCH[1]}
   		CURRMIDVERSION=${BASH_REMATCH[2]}
   		CURRMINORVERSION=${BASH_REMATCH[3]}
    fi
	#setUpNewVersion
    if [[ $2 =~ ^([0-9]*)\.([0-9]*)\.?([0-9]*?)$ ]]; then
   		NEWMAJORVERSION=${BASH_REMATCH[1]}
  		NEWMIDVERSION=${BASH_REMATCH[2]}
   		NEWMINORVERSION=${BASH_REMATCH[3]}
   	fi
	
    if [[("$CURRMAJORVERSION" -lt "$NEWMAJORVERSION")]]; then
   		MAJORVERSIONSTATUS="LESS"	
   	elif [[("$CURRMAJORVERSION" -eq "$NEWMAJORVERSION")]]; then
   		MAJORVERSIONSTATUS="EQUAL"
    elif [[("$CURRMAJORVERSION" -gt "$NEWMAJORVERSION")]]; then
    	MAJORVERSIONSTATUS="GREATER"
    fi
    
   	if [[("$CURRMIDVERSION" -lt "$NEWMIDVERSION")]]; then
   	 	MIDVERSIONSTATUS="LESS"	
    elif [[("$CURRMIDVERSION" -eq "$NEWMIDVERSION")]]; then
    	MIDVERSIONSTATUS="EQUAL"
    elif [[("$CURRMIDVERSION" -gt "$NEWMIDVERSION")]]; then
    	MIDVERSIONSTATUS="GREATER"
    fi
    	
    if [[(-z "$CURRMINORVERSION" && -z "$NEWMINORVERSION")]]; then
    	if [[("$CURRMINORVERSION" -lt "$NEWMINORVERSION")]]; then
   	 		MINORVERSIONSTATUS="LESS"	
    	elif [[("$CURRMIDVERSION" -eq "$NEWMIDVERSION")]]; then
    		MINORVERSIONSTATUS="EQUAL"
    	elif [[("$CURRMIDVERSION" -gt "$NEWMIDVERSION")]]; then
    		MINORVERSIONSTATUS="GREATER"
    	fi
	fi
    	
    if [[( -z "$CURRMINORVERSION" && (! -z "$NEWMINORVERSION"))]]; then
    	MINORVERSIONSTATUS="NEWERNULL"
	elif [[( (! -z "$CURRMINORVERSION") && -z "$NEWMINORVERSION")]]; then
		MINORVERSIONSTATUS="CURRENTNULL"
	elif [[( (! -z "$CURRMINORVERSION") && ( ! -z "$NEWMINORVERSION"))]]; then
		MINORVERSIONSTATUS="BOTHNULL"
	fi
		
	if [[("$MAJORVERSIONSTATUS" == "LESS")]]; then
		VERSIONCOMPARISON="LESS"
	elif [[("$MAJORVERSIONSTATUS" == "GREATER")]]; then
		VERSIONCOMPARISON="GREATER"
	elif [[("$MAJORVERSIONSTATUS" == "EQUAL" && "$MIDVERSIONSTATUS" == "LESS")]]; then
		VERSIONCOMPARISON="LESS"
	elif [[("$MAJORVERSIONTATUS" == "EQUAL" && "$MIDVERSIONSTATUS" == "GREATER")]]; then
		VERSIONCOMPARISON="GREATER"
	elif [[( (! -z "$CURRMINORVERSION" ) && (! -z "$NEWMINORVERSION"))]]; then
		VERSIONCOMPARISON="EQUAL"
	elif [[( "$MAJORVERSIONSTATUS" == "EQUAL" && "$MIDVERSIONSTATUS" == "EQUAL" && "$MINVERSIONSTATUS" == "LESS")]]; then
		VERSIONCOMPARISON="LESS"
	elif [[( "$MAJORVERSIONSTATUS" == "EQUAL" && "$MIDVERSIONSTATUS" == "EQUAL" && "$MINVERSIONSTATUS" == "GREATER")]]; then
		VERSIONCOMPARISON="GREATER"
	elif [[( "$MAJORVERSIONSTATUS" == "EQUAL" && "$MIDVERSIONSTATUS" == "EQUAL" && "$MINVERSIONSTATUS" == "EQUAL")]]; then
		VERSIONCOMPARISON="EQUAL"
	elif [[( "$MAJORVERSIONSTATUS" == "EQUAL" && "$MIDVERSIONSTATUS" == "EQUAL" && "$MINVERSIONSTATUS" == "NEWERNULL")]]; then
		VERSIONCOMPARISON="GREATER"
	elif [[( "$MAJORVERSIONSTATUS" == "EQUAL" && "$MIDVERSIONSTATUS" == "EQUAL" && "$MINVERSIONSTATUS" == "CURRENTNULL")]]; then
		VERSIONCOMPARISON="LESS"
	elif [[( "$MAJORVERSIONSTATUS" == "EQUAL" && "$MIDVERSIONSTATUS" == "EQUAL" && "$MINVERSIONSTATUS" == "BOTHNULL")]]; then
		VERSIONCOMPARISON="EQUAL"
	fi	
}

########################################
#Process the LATEST file for updates   #
########################################
processLatestVersionFile(){
	source LATEST
	#assume no update is needed until we know better 
	ISUPDATENEEDED="FALSE"
	
	for i in "${downloadURL[@]}"
	do
		#only continue testing if we haven't ascertained that we DO need to update.
		if [[( "$ISUPDATENEEDED" == "FALSE" )]]; then
			if [[ $i =~ ^(.*)\/(.*)\|(.*)\|(.*)$ ]]; then
    			BASEURL=${BASH_REMATCH[1]}
    			FILENAME=${BASH_REMATCH[2]}
    			DIRECTORYLOCATION=${BASH_REMATCH[3]}
    			LASTUPDATEDINVER=${BASH_REMATCH[4]}
    		fi
    		#Null out VERSIONCOMPARISON
    		VERSIONCOMPARISON=""
    		compareTwoVersions $SCRIPTVERSION $LASTUPDATEDINVER
    	
    		if [[("$VERSIONCOMPARISON" == "LESS")]]; then
    				ISUPDATENEEDED="TRUE"
			elif [[("$VERSIONCOMPARISON" == "EQUAL")]]; then
					ISUPDATENEEDED="FALSE"
			elif [[("$VERSIONCOMPARISON" == "GREATER")]]; then
					ISUPDATENEEDED="FALSE"
			fi
		fi
	done
	
	if [[("$ISUPDATENEEDED" == "TRUE")]]; then
		LOOP="1"
		echo "An update to the script is available, it is STRONGLY recommended that you update prior to using ASM."
		echo "Would you like to update the script now? yes/no [yes]:"
		
		while [ $LOOP -eq "1" ]
		do
			read USERWANTSUPDATE
			if [[("${USERWANTSUPDATE,,}" == "y" || "${USERWANTSUPDATE,,}" == "yes")]]; then
				USERWANTSUPDATE="TRUE"
				LOOP="0"
			elif [[("${USERWANTSUPDATE,,}" == "n" || "${USERWANTSUPDATE,,}" == "no")]]; then
				USERWANTSUPDATE="FALSE"
				LOOP="0"
			else
				echo ""
				echo "Your input was not recognised, please enter 'Yes' or 'No'. Would you like to update the script now? yes/no [yes]:" 
			fi
		done
		
		if [[("$USERWANTSUPDATE" == "TRUE")]]; then
			for i in "${downloadURL[@]}"
			do
				if [[ $i =~ ^(.*)\/(.*)\|(.*)\|(.*)$ ]]; then
    				BASEURL=${BASH_REMATCH[1]}
    				FILENAME=${BASH_REMATCH[2]}
    				DIRECTORYLOCATION=${BASH_REMATCH[3]}
    				LASTUPDATEDINVER=${BASH_REMATCH[4]}
    			fi
    			#Possibly for future, look at updating only files that are required in a future release
				echo "Downloading the latest version of $FILENAME. Please Wait..."
				cd $INSTALLDIR$DIRECTORYLOCATION
				mv $FILENAME .$FILENAME.OLD
				if ! wget --quiet $BASEURL/$FILENAME ; then
    				mv .$FILENAME.OLD $FILENAME
    				echo "Unable to update $FILENAME please try again later. The script will continue using the existing version."
				fi
				echo "Updated $FILENAME successfully"
				echo ""
				echo ""
			done
			
			chmod a+x $INSTALLDIR/atlassianSuiteManager.sh
			echo "ASM has been updated and will now terminate, please run ASM again to use the new version."
			exit 0
		fi
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

#If we don't have a LATEST file get one.
if [ ! -f "LATEST" ]; then
	echo "Please wait, checking for updates..."
	downloadLatestFile
	processLatestVersionFile
else
	#only check for updates if we havent in the last 24 hours.
	if test `find "LATEST" -mmin +1440`; then
    echo "Please wait, checking for updates..."
    downloadLatestFile
	fi
fi

processLatestVersionFile

checkPerlModules
cd $INSTALLDIR
perl perl/AtlassianSuiteManager.pl $ARGS

exit 0
