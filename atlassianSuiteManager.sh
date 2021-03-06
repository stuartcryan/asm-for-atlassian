#!/bin/bash

#
#    Copyright 2012-2014 Stuart Ryan
#
#    Application Name: ASM Script for Atlassian(R)
#    Application URI: http://technicalnotebook.com/wiki/display/ATLASSIANMGR
#    Version: 0.2.7
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

SCRIPTVERSION="0.2.7"
LATESTDOWNLOADURL="http://akamai.technicalnotebook.com/asmGitPublicRepo/LATEST"
LATESTSUPPORTEDDOWNLOADURL="http://akamai.technicalnotebook.com/asmGitPublicRepo/supportedVersions.cfg"
EXPATDOWNLOADURL="http://sourceforge.net/projects/expat/files/latest/download"
clear
INSTALLDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

type yum >/dev/null 2>&1 || YUM="FALSE"
type apt-get >/dev/null 2>&1 || APTGET="FALSE"

if [[ $APTGET != "FALSE" ]]; then
	type -P lsb_release &>/dev/null  || { $LSB_RELEASE="FALSE"; }
	if [[ $LSB_RELEASE == "FALSE" ]]; then
		apt-get -y install lsb-release || { echo "apt-get Was unable to install lsb-release. You will need to install this manually and fix before proceeding. This script will now exit"; exit 1; }
	fi
fi


if [[ $APTGET != "FALSE" ]]; then
	LSBRELEASEOUT=`lsb_release -i`
	if [[ "$LSBRELEASEOUT" == *Debian* ]]; then
		OPERATING_SYSTEM="DEBIAN";
	elif [[ "$LSBRELEASEOUT" == *Ubuntu* ]]; then
		OPERATING_SYSTEM="UBUNTU";
	else
		OPERATING_SYSTEM="OTHER"
	fi
elif [[ -e "/etc/redhat-release" ]]; then
	OPERATING_SYSTEM="REDHAT"
else
	OPERATING_SYSTEM="OTHER"
fi

########################################
#Check for SELinux                     #
########################################
checkSELinux(){

type -P getenforce &>/dev/null  || { SELINUXCHECK="UNABLE";}

if [[ $SELINXUXCHECK != "UNABLE" && $DISABLESELINUXCHECK != "TRUE" ]]; then
 	SELINUXSTATUS=`getenforce`
 	 	
 	if [[ $SELINUXSTATUS == "Enforcing" ]]; then
 	echo "It appears that SELinux is currently set to Enforcing. This script has not been certified to install and configure the Atlassian Suite with SELinux enabled."
 	echo ""
    echo -n "If you continue you may run into unusual problems trying to get the applications to run. Do you wish to continue? yes/no [no]: "
 	LOOP=1
		while [ $LOOP -eq "1" ]
		do
			read USERWANTSTOPROCEEDWITHSELINUX
			if [[("$USERWANTSTOPROCEEDWITHSELINUX" == "y" || "$USERWANTSTOPROCEEDWITHSELINUX" == "yes"|| "$USERWANTSTOPROCEEDWITHSELINUX" == "YES" || "$USERWANTSTOPROCEEDWITHSELINUX" == "Yes" || "$USERWANTSTOPROCEEDWITHSELINUX" == "YEs" || "$USERWANTSTOPROCEEDWITHSELINUX" == "yEs" || "$USERWANTSTOPROCEEDWITHSELINUX" == "YeS")]]; then
				LOOP="0"
                echo -n "Do you wish to disable this check in future? yes/no [yes]: "
                    
                INNERLOOP=1
		        while [ $INNERLOOP -eq "1" ]
	            do
		            read USERWANTSTODISABLESELINUXCHECK
		            if [[("$USERWANTSTODISABLESELINUXCHECK" == "y" || "$USERWANTSTODISABLESELINUXCHECK" == "yes"|| "$USERWANTSTODISABLESELINUXCHECK" == "YES" || "$USERWANTSTODISABLESELINUXCHECK" == "Yes" || "$USERWANTSTODISABLESELINUXCHECK" == "YEs" || "$USERWANTSTODISABLESELINUXCHECK" == "yEs" || "$USERWANTSTODISABLESELINUXCHECK" == "YeS" || "$USERWANTSTODISABLESELINUXCHECK" == "")]]; then
		                INNERLOOP="0"
                        if [ -f "shellScriptIncludes.inc" ]; then
                            echo "" >> shellScriptIncludes.inc
                            echo "DISABLESELINUXCHECK=TRUE" >> shellScriptIncludes.inc
                        else
                            echo "#!/bin/bash" >> shellScriptIncludes.inc
                            echo "#    This file can contain custom configuration and script configs for the atlassianSuiteManger.sh script" >> shellScriptIncludes.inc
						    echo "#"  >> shellScriptIncludes.inc
						    echo "#    Copyright 2012-2014 Stuart Ryan" >> shellScriptIncludes.inc
						    echo "" >> shellScriptIncludes.inc
                            echo "DISABLESELINUXCHECK=TRUE" >> shellScriptIncludes.inc
                        fi
                    
			        elif [[("$USERWANTSTODISABLESELINUXCHECK" == "n" || "$USERWANTSTODISABLESELINUXCHECK" == "no" || "$USERWANTSTODISABLESELINUXCHECK" == "NO" || "$USERWANTSTODISABLESELINUXCHECK" == "No" || "$USERWANTSTODISABLESELINUXCHECK" == "nO")]]; then
			            INNERLOOP="0"
		           else
			            echo ""
			            echo -n "Your input was not recognised, please enter 'Yes' or 'No'. Do you wish to disable the SELinux check in future? yes/no [yes]: " 
		           fi
		       done
                    
			elif [[("$USERWANTSTOPROCEEDWITHSELINUX" == "n" || "$USERWANTSTOPROCEEDWITHSELINUX" == "no" || "$USERWANTSTOPROCEEDWITHSELINUX" == "NO" || "$USERWANTSTOPROCEEDWITHSELINUX" == "No" || "$USERWANTSTOPROCEEDWITHSELINUX" == "nO"|| "$USERWANTSTOPROCEEDWITHSELINUX" == "")]]; then
				echo ""
				echo "Please disable SELinux (search 'Disable SELinux' on Google) and then restart your machine and then run this script again."
				echo ""
				echo ""
				LOOP="0"
				exit 1
			else
				echo ""
				echo -n "Your input was not recognised, please enter 'Yes' or 'No'. Do you wish to continue even though SELinux is Enforcing? yes/no [no]: " 
			fi
		done
 	
    fi
fi
}


########################################
#Test system for required Binaries     #
########################################
checkRequiredBinaries(){
BINARIES="wget zip unzip tar gzip perl cpan gcc openssl g++ make"

#as Debian does not know of a CPAN binary it comes in the PERL binary
BINARIESREDHAT="wget zip unzip tar gzip perl gcc gcc-c++ make cpan"
BINARIESDEBIAN="wget zip unzip tar gzip perl gcc g++ make"

#These are deliberately null
BINARIESCHECK=""
MISSINGBINARIES=""

for i in $BINARIES
do
   type -P $i &>/dev/null  || { echo "'$i' binary not found."; BINARIESCHECK="FAIL"; }
done

if [[ ! -e "/usr/include/openssl/ssl.h" ]]; then
	BINARIESCHECK="FAIL"
	#add openssl-devel to the required binaries
	BINARIESREDHAT="$BINARIESREDHAT openssl-devel"
	if [[ $OPERATING_SYSTEM == "UBUNTU" ]]; then
		BINARIESDEBIAN="$BINARIESDEBIAN libssl-dev openssl"
	elif [[ $OPERATING_SYSTEM == "DEBIAN" ]]; then
		BINARIESDEBIAN="$BINARIESDEBIAN libssl-dev openssl"
	fi
	echo "'openssl-devel/libssl-dev' libraries not found.";
fi

#adding check for getEnforce for Ubuntu and DEBIAN
if [[ $OPERATING_SYSTEM == "UBUNTU" || $OPERATING_SYSTEM == "DEBIAN" ]]; then
   type -P getenforce &>/dev/null
    if [[ $? -ne 0 ]]; then
     	BINARIESCHECK="FAIL"
	    #add selinux-utils to the required binaries
	    BINARIESDEBIAN="$BINARIESDEBIAN selinux-utils"
    fi
fi

# Adding expat and expat-devel package tests as per [#ATLASMGR-295] to fix bug on CentOS 5 machines
if [[ $OPERATING_SYSTEM == "REDHAT" ]]; then
    rpm -q expat-devel >> /dev/null 2>&1
    if [[ $? -ne 0 ]]; then
     	BINARIESCHECK="FAIL"
	    #add expat-devel to the required binaries
	    BINARIESREDHAT="$BINARIESREDHAT expat-devel"
    fi
    
    rpm -q expat >> /dev/null 2>&1
    if [[ $? -ne 0 ]]; then
	    BINARIESCHECK="FAIL"
	    #add expat-devel to the required binaries
	    BINARIESREDHAT="$BINARIESREDHAT expat"
    fi
fi

if [[ $BINARIESCHECK == "FAIL" ]] ; then
   echo ""
echo -n "Some required binary components are missing therefore this script cannot be run. Would you like the script to attempt to install them? yes/no [yes]: "
   LOOP=1
		while [ $LOOP -eq "1" ]
		do
			read USERWANTSINSTALLPREREQ
			if [[("$USERWANTSINSTALLPREREQ" == "y" || "$USERWANTSINSTALLPREREQ" == "yes"|| "$USERWANTSINSTALLPREREQ" == "YES" || "$USERWANTSINSTALLPREREQ" == "Yes" || "$USERWANTSINSTALLPREREQ" == "YEs" || "$USERWANTSINSTALLPREREQ" == "yEs" || "$USERWANTSINSTALLPREREQ" == "YeS" || "$USERWANTSINSTALLPREREQ" == "")]]; then
				USERWANTSPREREQS="TRUE"
				LOOP="0"
			elif [[("$USERWANTSINSTALLPREREQ" == "n" || "$USERWANTSINSTALLPREREQ" == "no" || "$USERWANTSINSTALLPREREQ" == "NO" || "$USERWANTSINSTALLPREREQ" == "No" || "$USERWANTSINSTALLPREREQ" == "nO")]]; then
				USERWANTSPREREQS="FALSE"
				echo ""
				echo "Please install the required binaries and then run this script again."
				echo ""
				echo ""
				LOOP="0"
				exit 1
			else
				echo ""
				echo -n "Your input was not recognised, please enter 'Yes' or 'No'. Would you like to update the script now? yes/no [yes]: " 
			fi
		done
		
		if [[ ($USERWANTSPREREQS == "TRUE") ]]; then
			
			if [[ ($YUM != "FALSE") ]]; then
				yum -y install $BINARIESREDHAT || { echo "YUM Was unable to install all the required binaries. You will need to check this manually and fix before proceeding. This script will now exit"; exit 1; }
			elif [[ ($APTGET != "FALSE") ]]; then
				apt-get -y install $BINARIESDEBIAN || { echo "apt-get Was unable to install all the required binaries. You will need to check this manually and fix before proceeding. This script will now exit"; exit 1; }
			else
			echo "It appears we are unable to find either yum (Redhat/CentOS) or apt-get (Debian/Ubuntu). Therefore you will have to install missing binaries manually. Please install the missing binaries and start the script again."
			exit 1
			fi
		fi
fi

}

installExpat(){
	#Run in tmp as make for expat has problems with paths with spaces
	cd /tmp
	wget $PROXYUSER $PROXYPASS --output-document=expat.tar.gz $EXPATDOWNLOADURL || { echo "WGET Was unable to download EXPAT, please check your internet connection and try again. This script will now exit."; exit 1; }
	tar -xvzf expat.tar.gz
	cd expat-*
    ./configure || { echo "Unable to configure EXPAT. Without EXPAT the PERL XML binaries will not install correctly. Please correct this manually and then run this script again. This script will now exit"; exit 1; }
    make || { echo "Unable to 'make' EXPAT. Without EXPAT the PERL XML binaries will not install correctly. Please correct this manually and then run this script again. This script will now exit"; exit 1; }
    make install || { echo "Unable to 'make install' EXPAT. Without EXPAT the PERL XML binaries will not install correctly. Please correct this manually and then run this script again. This script will now exit"; exit 1; }
    cd ../
    rm -r --force expat-*
}

checkJVM(){
	java -version  2>&1 | grep HotSpot || { java -version || { echo ""; echo ""; echo "Java is not currently installed. Please install an Oracle JDK (not OpenJDK) and run this script again. This script will now exit."; echo ""; exit 1; }; echo ""; echo ""; echo "The Java Runtime Environment currently installed is OpenJDK. At this time the Atlassian Suite does not support OpenJDK. Please install an Oracle JDK and run this script again. This script will now exit."; echo ""; exit 1; }
}

########################################
#Test system for required PERL Modules #
########################################
checkPerlModules(){
MODULES="LWP::Simple JSON Data::Dumper Config::Simple Crypt::SSLeay URI XML::Parser XML::XPath XML::Twig Archive::Extract Socket Getopt::Long Log::Log4perl Archive::Tar Archive::Zip Filesys::DfPortable ExtUtils::Installed File::Basename Net::SSLGlue::LWP"
BINARIESCHECK=""
MISSINGMODULES=""

PERLVERSION=`grep "my \\$scriptVersion =" $INSTALLDIR/perl/AtlassianSuiteManager.pl`
if [[ $PERLVERSION =~ ^.*\"([0-9]*)-([0-9]*)-?([0-9]*?)\".*?$ ]]; then
	if [[ ${BASH_REMATCH[3]} == "" ]]; then
		PERLVERSION=${BASH_REMATCH[1]}.${BASH_REMATCH[2]}
	else
		PERLVERSION=${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}
	fi
fi
	
SETTINGSCONFVERSION=`grep "asmPatchLevel=" $INSTALLDIR/settings.cfg`
if [[ $FORCEPERLMODULES == "FALSE" && $SETTINGSCONFVERSION == "" ]]; then
	FORCEPERLMODULES="TRUE"
elif [[ $FORCEPERLMODULES == "TRUE" ]]; then
	FORCEPERLMODULES="TRUE"
else
	FORCEPERLMODULES="FALSE"
fi

if [[ $FORCEPERLMODULES == "FALSE" && $SETTINGSCONFVERSION =~ ([0-9]*)-([0-9]*)?-?([0-9]*)?.*$ ]]; then
	if [[ ${BASH_REMATCH[3]} == "" ]]; then
		SETTINGSCONFVERSION=${BASH_REMATCH[1]}.${BASH_REMATCH[2]}
	else
		SETTINGSCONFVERSION=${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}
	fi
fi
	
compareTwoVersions $SETTINGSCONFVERSION $PERLVERSION
   	
if [[($FORCEPERLMODULES == "TRUE") || ("$VERSIONCOMPARISON" == "LESS")]]; then

	for i in $MODULES
	do
		perl -e "use $i" &>/dev/null  || { echo "$i PERL module not found."; MODULESCHECK="FAIL"; MISSINGMODULES=$MISSINGMODULES"$i "; }
	done

	if [[ $MODULESCHECK == "FAIL" ]] ; then
   		echo -n "Some required PERL modules are missing therefore this script cannot be run. Would you like the script to attempt to install them? yes/no [yes]: "
  		LOOP=1
		while [ $LOOP -eq "1" ]
		do
			read USERWANTSINSTALLPREREQ
			if [[("$USERWANTSINSTALLPREREQ" == "y" || "$USERWANTSINSTALLPREREQ" == "yes"|| "$USERWANTSINSTALLPREREQ" == "YES" || "$USERWANTSINSTALLPREREQ" == "Yes" || "$USERWANTSINSTALLPREREQ" == "YEs" || "$USERWANTSINSTALLPREREQ" == "yEs" || "$USERWANTSINSTALLPREREQ" == "YeS" || "$USERWANTSINSTALLPREREQ" == "")]]; then
				USERWANTSPREREQS="TRUE"
				LOOP="0"
			elif [[("$USERWANTSINSTALLPREREQ" == "n" || "$USERWANTSINSTALLPREREQ" == "no" || "$USERWANTSINSTALLPREREQ" == "NO" || "$USERWANTSINSTALLPREREQ" == "No" || "$USERWANTSINSTALLPREREQ" == "nO")]]; then
				USERWANTSPREREQS="FALSE"
				echo ""
				echo "Please manually install the required PERL modules listed above and then run this script again."
				echo ""
				echo ""
				LOOP="0"
				exit 1
			else
				echo ""
				echo -n "Your input was not recognised, please enter 'Yes' or 'No'. Would you like to update the script now? yes/no [yes]:" 
			fi
		done
		
		if [[($USERWANTSPREREQS == "TRUE")]]; then
			echo ""
			echo -n "CPAN provides the ability to automatically install all dependencies without prompting. This is highly recommended and will save you a LOT of time... Would you like us to configure this? yes/no [yes]: "
			LOOP2=1
		while [ $LOOP2 -eq "1" ]
		do
			read UPDATECPANCONF
			if [[("$UPDATECPANCONF" == "y" || "$UPDATECPANCONF" == "yes"|| "$UPDATECPANCONF" == "YES" || "$UPDATECPANCONF" == "Yes" || "$UPDATECPANCONF" == "YEs" || "$UPDATECPANCONF" == "yEs" || "$UPDATECPANCONF" == "YeS" || "$UPDATECPANCONF" == "")]]; then
				UPDATECPANCONF="TRUE"
				LOOP2="0"
			elif [[("$UPDATECPANCONF" == "n" || "$UPDATECPANCONF" == "no" || "$UPDATECPANCONF" == "NO" || "$UPDATECPANCONF" == "No" || "$UPDATECPANCONF" == "nO")]]; then
				UPADTECPANCONF="FALSE"
				LOOP2="0"
			else
				echo ""
				echo -n "Your input was not recognised, please enter 'Yes' or 'No'. Would you like to enable dependencies following with minimal input? yes/no [yes]:" 
			fi
		done
		
			#Final confirmation to USER
			echo ""
			echo "We are now ready to begin the installation, we will install all required PERL modules as well as EXPAT (built from source) to support the XML PERL Modules."
			echo "You will need to provide input several times, please ensure you just accept any default options that the PERL installers ask for."
			echo "Please press enter to continue..."
			
			read ASKUSERTOPRESSENTER
			 
			#Test if XML::Parser is installed again
			perl -e "use XML::Parser" &>/dev/null  || { XMLPARSER="FAIL"; }
			if [[($XMLPARSER == "FAIL")]]; then
				installExpat
			fi
			
			#Tell PERL/CPAN to accept all defaults
			PERL_MM_USE_DEFAULT=1
			#install local::lib to support ubuntu sudo, try twice as the first time seems to fail
			cpan "local::lib" || { cpan "local::lib" || { echo "CPAN was unable to install YAML. Please correct this manually and then run this script again. This script will now exit"; exit 1; } }
			cpan "YAML" || { echo "CPAN was unable to install YAML. Please correct this manually and then run this script again. This script will now exit"; exit 1; }
			if [[($USERWANTSPREREQS == "TRUE")]]; then
				(echo o conf prerequisites_policy follow;echo o conf commit)|cpan
			fi
			
			perl -e "use LWP::Simple" &>/dev/null  || { cpan "LWP::Simple" || { echo "CPAN was unable to install LWP::Simple. Please correct this manually and then run this script again. This script will now exit"; exit 1; } ; }
			cpan $MISSINGMODULES || { echo "CPAN was unable to install the required PERL modules. Please correct this manually and then run this script again. This script will now exit"; exit 1; }
		fi
	fi
fi
}

########################################
#Download new copy of LATEST file      #
########################################
downloadLatestFile(){
	cd $INSTALLDIR
	if [[ -e LATEST ]]; then
	   mv LATEST .LATEST.OLD
    fi

	if ! wget $PROXYUSER $PROXYPASS --quiet $LATESTDOWNLOADURL ; then
    	mv .LATEST.OLD LATEST
	fi
}

##########################################
#Download new copy of supportedVersioncfg#
##########################################
downloadSupportedVersionsFile(){
	cd $INSTALLDIR
	if [[ -e supportedVersions.cfg ]]; then
	   mv supportedVersions.cfg .supportedVersions.cfg.OLD
    fi

	if ! wget $PROXYUSER $PROXYPASS --quiet $LATESTSUPPORTEDDOWNLOADURL ; then
    	mv .supportedVersions.cfg.OLD supportedVersions.cfg
	fi
}

########################################
#Compare two versions to find newer    #
########################################
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
    	
    if [[(-n "$CURRMINORVERSION" && -n "$NEWMINORVERSION")]]; then
    	if [[("$CURRMINORVERSION" -lt "$NEWMINORVERSION")]]; then
   	 		MINORVERSIONSTATUS="LESS"	
    	elif [[("$CURRMINORVERSION" -eq "$NEWMINORVERSION")]]; then
    		MINORVERSIONSTATUS="EQUAL"
    	elif [[("$CURRMINORVERSION" -gt "$NEWMINORVERSION")]]; then
    		MINORVERSIONSTATUS="GREATER"
    	fi
	fi
    	
    if [[( -n "$CURRMINORVERSION" && ( -z "$NEWMINORVERSION"))]]; then
    	MINORVERSIONSTATUS="NEWERNULL"
	elif [[( ( -z "$CURRMINORVERSION") && -n "$NEWMINORVERSION")]]; then
		MINORVERSIONSTATUS="CURRENTNULL"
	elif [[( ( -z "$CURRMINORVERSION") && (  -z "$NEWMINORVERSION"))]]; then
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
	elif [[( ( -z "$CURRMINORVERSION" ) && ( -z "$NEWMINORVERSION"))]]; then
		VERSIONCOMPARISON="EQUAL"
	elif [[( "$MAJORVERSIONSTATUS" == "EQUAL" && "$MIDVERSIONSTATUS" == "EQUAL" && "$MINORVERSIONSTATUS" == "LESS")]]; then
		VERSIONCOMPARISON="LESS"
	elif [[( "$MAJORVERSIONSTATUS" == "EQUAL" && "$MIDVERSIONSTATUS" == "EQUAL" && "$MINORVERSIONSTATUS" == "GREATER")]]; then
		VERSIONCOMPARISON="GREATER"
	elif [[( "$MAJORVERSIONSTATUS" == "EQUAL" && "$MIDVERSIONSTATUS" == "EQUAL" && "$MINORVERSIONSTATUS" == "EQUAL")]]; then
		VERSIONCOMPARISON="EQUAL"
	elif [[( "$MAJORVERSIONSTATUS" == "EQUAL" && "$MIDVERSIONSTATUS" == "EQUAL" && "$MINORVERSIONSTATUS" == "NEWERNULL")]]; then
		VERSIONCOMPARISON="GREATER"
	elif [[( "$MAJORVERSIONSTATUS" == "EQUAL" && "$MIDVERSIONSTATUS" == "EQUAL" && "$MINORVERSIONSTATUS" == "CURRENTNULL")]]; then
		VERSIONCOMPARISON="LESS"
	elif [[( "$MAJORVERSIONSTATUS" == "EQUAL" && "$MIDVERSIONSTATUS" == "EQUAL" && "$MINORVERSIONSTATUS" == "BOTHNULL")]]; then
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
	PERLVERSION=`grep "my \\$scriptVersion =" $INSTALLDIR/perl/AtlassianSuiteManager.pl`
	if [[ $PERLVERSION =~ ^.*\"([0-9]*)-([0-9]*)-?([0-9]*?)\".*?$ ]]; then
		if [[ ${BASH_REMATCH[3]} == "" ]]; then
			PERLVERSION=${BASH_REMATCH[1]}.${BASH_REMATCH[2]}
		else
			PERLVERSION=${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}
		fi
	fi
	
		#only continue testing if we haven't ascertained that we DO need to update.
	if [[( "$ISUPDATENEEDED" == "FALSE" )]]; then

   		BASEURL=${latestPerlFile[0]}
   		FILENAME=${latestPerlFile[1]}
   		DIRECTORYLOCATION=${latestPerlFile[2]}
   		LASTUPDATEDINVER=${latestPerlFile[3]}

   		#Null out VERSIONCOMPARISON
   		VERSIONCOMPARISON=""
   		compareTwoVersions $PERLVERSION $LASTUPDATEDINVER
   	
   		if [[("$VERSIONCOMPARISON" == "LESS")]]; then
   				ISUPDATENEEDED="TRUE"
		elif [[("$VERSIONCOMPARISON" == "EQUAL")]]; then
				ISUPDATENEEDED="FALSE"
		elif [[("$VERSIONCOMPARISON" == "GREATER")]]; then
				ISUPDATENEEDED="FALSE"
		fi
	fi
	
	if [[( "$ISUPDATENEEDED" == "FALSE" )]]; then
	
		BASEURL=${latestWrapperFile[0]}
   		FILENAME=${latestWrapperFile[1]}
   		DIRECTORYLOCATION=${latestWrapperFile[2]}
   		LASTUPDATEDINVER=${latestWrapperFile[3]}

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
	
	if [[("$ISUPDATENEEDED" == "TRUE")]]; then
		LOOP="1"
	
		echo "An update to the script is available, it is STRONGLY recommended that you update prior to using ASM."
		echo ""
		echo "$changeLog"
		echo ""
		echo -n "Would you like to update the script now? yes/no [yes]:"
		
		while [ $LOOP -eq "1" ]
		do
			read USERWANTSUPDATE
			if [[("$USERWANTSUPDATE" == "y" || "$USERWANTSUPDATE" == "yes"|| "$USERWANTSUPDATE" == "YES" || "$USERWANTSUPDATE" == "Yes" || "$USERWANTSUPDATE" == "YEs" || "$USERWANTSUPDATE" == "yEs" || "$USERWANTSUPDATE" == "YeS" || "$USERWANTSUPDATE" == "")]]; then
				USERWANTSUPDATE="TRUE"
				LOOP="0"
			elif [[("$USERWANTSUPDATE" == "n" || "$USERWANTSUPDATE" == "no" || "$USERWANTSUPDATE" == "NO" || "$USERWANTSUPDATE" == "No" || "$USERWANTSUPDATE" == "nO")]]; then
				USERWANTSUPDATE="FALSE"
				echo ""
				echo ""
				LOOP="0"
			else
				echo ""
				echo "Your input was not recognised, please enter 'Yes' or 'No'. Would you like to update the script now? yes/no [yes]:" 
			fi
		done
		
		if [[("$USERWANTSUPDATE" == "TRUE")]]; then
			BASEURL=${latestPerlFile[0]}
   			FILENAME=${latestPerlFile[1]}
   			DIRECTORYLOCATION=${latestPerlFile[2]}
   			LASTUPDATEDINVER=${latestPerlFile[3]}
    		#Possibly for future, look at updating only files that are required in a future release
			echo "Downloading the latest version of $FILENAME. Please Wait..."
			cd $INSTALLDIR$DIRECTORYLOCATION
			mv $FILENAME .$FILENAME.OLD
			if ! wget $PROXYUSER $PROXYPASS --quiet $BASEURL/$FILENAME ; then
				mv .$FILENAME.OLD $FILENAME
				echo "Unable to update $FILENAME please try again later. The script will continue using the existing version."
			fi
			echo "Updated $FILENAME successfully"
			echo ""
			echo ""
			
			BASEURL=${latestWrapperFile[0]}
   			FILENAME=${latestWrapperFile[1]}
   			DIRECTORYLOCATION=${latestWrapperFile[2]}
   			LASTUPDATEDINVER=${latestWrapperFile[3]}
    		#Possibly for future, look at updating only files that are required in a future release
			echo "Downloading the latest version of $FILENAME. Please Wait..."
			cd $INSTALLDIR$DIRECTORYLOCATION
			mv $FILENAME .$FILENAME.OLD
			if ! wget $PROXYUSER $PROXYPASS --quiet $BASEURL/$FILENAME ; then
				mv .$FILENAME.OLD $FILENAME
				echo "Unable to update $FILENAME please try again later. The script will continue using the existing version."
			fi
			echo "Updated $FILENAME successfully"
			echo ""
			echo ""
			
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
	echo ""
	echo "This script must be run as root. Terminating..." 1>&2
	echo ""
	echo ""
	echo ""
	exit 1
fi
}

#Import custom includes if the file exists
if [ -f "shellScriptIncludes.inc" ]; then
	source shellScriptIncludes.inc
	if [[ $PROXYUSER ]]; then
		PROXYUSER="--proxy-user="$PROXYUSER 
	fi 
	if [[ $PROXYPASS ]]; then
		PROXYPASS="--proxy-password="$PROXYPASS 
	fi
fi

#Do initial checks
checkForRootAccess
checkSELinux

#check for Oracle JVM
clear

#Display nice header
	cat <<-____HERE
      Welcome to the ASM Script for Atlassian(R)

      Copyright (C) 2012-2014  Stuart Ryan
      
      This program comes with ABSOLUTELY NO WARRANTY;
      This is free software, and you are welcome to redistribute it
      under certain conditions; read the COPYING file included for details.

      ****************************************
      *Checking for Oracle JVM               *
      ****************************************
    
	____HERE
	
checkJVM

clear

#Display nice header
	cat <<-____HERE
      Welcome to the ASM Script for Atlassian(R)

      Copyright (C) 2012-2014  Stuart Ryan
      
      This program comes with ABSOLUTELY NO WARRANTY;
      This is free software, and you are welcome to redistribute it
      under certain conditions; read the COPYING file included for details.

      ****************************************
      * Checking for updates please wait...  *
      ****************************************
    
	____HERE

#If we don't have a LATEST update file get one.
if [ ! -f "LATEST" ]; then
	downloadLatestFile
	processLatestVersionFile
else
	#Only download a new file if we haven't in the last 24 hours.
	if test `find "LATEST" -mmin +1440`; then
    downloadLatestFile
	fi
fi

#If we don't have a supportedVersions.cfg file get one.
if [ ! -f "supportedVersions.cfg" ]; then
	downloadSupportedVersionsFile
else
	#Only download a new file if we haven't in the last 24 hours.
	if test `find "supportedVersions.cfg" -mmin +1440`; then
    downloadSupportedVersionsFile
	fi
fi

#process the update file each time the script runs (hint hint... you should be upgrading)
processLatestVersionFile

#check for the required binaries and modules
clear

#Display nice header
	cat <<-____HERE
      Welcome to the ASM Script for Atlassian(R)

      Copyright (C) 2012-2014  Stuart Ryan
      
      This program comes with ABSOLUTELY NO WARRANTY;
      This is free software, and you are welcome to redistribute it
      under certain conditions; read the COPYING file included for details.

      ****************************************
      *Checking for required system binaries *
      ****************************************
    
	____HERE
	
checkRequiredBinaries

clear
#Display nice header
	cat <<-____HERE
      Welcome to the ASM Script for Atlassian(R)

      Copyright (C) 2012-2014  Stuart Ryan
      
      This program comes with ABSOLUTELY NO WARRANTY;
      This is free software, and you are welcome to redistribute it
      under certain conditions; read the COPYING file included for details.

      ****************************************
      * Checking for required PERL modules   *
      ****************************************
    
	____HERE

args=("$@")
if [[(${args[0]} == "--force-perl-modules-check")]]; then
FORCEPERLMODULES="TRUE"
else
FORCEPERLMODULES="FALSE"
fi

checkPerlModules

#run the perl script
cd $INSTALLDIR
perl perl/AtlassianSuiteManager.pl $@

exit 0