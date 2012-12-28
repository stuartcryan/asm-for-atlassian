#!/usr/bin/perl

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

use LWP::Simple;    # From CPAN
use LWP::Simple qw($ua getstore);
use JSON qw( decode_json );    # From CPAN
use JSON qw( from_json );      # From CPAN
use URI;                       # From CPAN
use POSIX qw(strftime);
use Data::Dumper;              # Perl core module
use Config::Simple;            # From CPAN
use File::Copy;
use File::Path qw(make_path remove_tree);
use File::Path;
use File::Find;
use Archive::Extract;
use FindBin '$Bin';
use XML::Twig;
use Socket qw( PF_INET SOCK_STREAM INADDR_ANY sockaddr_in );
use Errno qw( EADDRINUSE );
use Getopt::Long;
use Log::Log4perl;
use strict;                    # Good practice
use warnings;                  # Good practice

Getopt::Long::Configure("bundling");
Log::Log4perl->init("log4j.conf");

########################################
#Set Up Variables                      #
########################################
my $globalConfig;
my $configFile = "settings.cfg";
my $distro;
my $silent                  = '';    #global flag for command line paramaters
my $debug                   = '';    #global flag for command line paramaters
my $unsupported             = '';    #global flag for command line paramaters
my $ignore_version_warnings = '';    #global flag for command line paramaters
my $disable_config_checks   = '';    #global flag for command line paramaters
my $verbose                 = '';    #global flag for command line paramaters
my $globalArch;
my $log = Log::Log4perl->get_logger("");

########################################
#TestOSArchitecture                    #
########################################
sub testOSArchitecture {
	if (`uname -m | grep -i "x86_64"`) {
		return "64";
	}
	else {
		return "32";
	}
}

########################################
#GetUserCreatedByInstaller             #
#The atlassian BIN installers for      #
#Confluence and JIRA currently create  #
#their own users, we need to get this  #
#following installation so that we can #
#chmod files correctly.                #
########################################
sub getUserCreatedByInstaller {
	my $parameterName;
	my $lineReference;
	my $searchFor;
	my @data;
	my $fileName;
	my $userName;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	$parameterName = $_[0];
	$lineReference = $_[1];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_parameterName", $parameterName );
	dumpSingleVarToLog( "$subname" . "_lineReference", $lineReference );

	$fileName = $globalConfig->param($parameterName) . "/bin/user.sh";

	dumpSingleVarToLog( "$subname" . "_fileName", $fileName );

	open( FILE, $fileName ) or $log->logdie("Unable to open file: $fileName.");

	# read file into an array
	@data = <FILE>;

	close(FILE);

	#Search for reference line
	my ($index1) = grep { $data[$_] =~ /^$lineReference.*/ } 0 .. $#data;

	#If you cant find the first reference try for the second reference
	if ( !defined($index1) ) {
		$log->logdie("Unable to get username from $fileName.");
	}
	else {
		if ( $data[$index1] =~ /.*=\"(.*?)\".*/ ) {
			my $result1 = $1;
			return $result1;
		}
	}
}

########################################
#dumpVarsToLog                         #
########################################
sub dumpVarsToLog {

	my @varNames  = $_[0];
	my @varValues = $_[1];

	if ( $log->is_debug() ) {
		my $counter = 0;
		while ( $counter <= $#varNames ) {
			$log->debug("VARDUMP: $varNames[$counter]: $varValues[$counter]");
			$counter++;
		}
	}
}

########################################
#dumpsingleVarToLog                    #
########################################
sub dumpSingleVarToLog {

	my $varName  = $_[0];
	my $varValue = $_[1];
	if ( $log->is_debug() ) {
		$log->debug("VARDUMP: $varName: $varValue");
	}
}

########################################
#getConfigItem                         #
########################################
sub getConfigItem {

#This function can be used if a config item may have a NULL defined deliberately to return the correct value.
	my $configItem;
	my $cfg;

	$configItem = $_[0];
	$cfg        = $_[1];

	if ( $cfg->param($configItem) eq "NULL" ) {
		return "";
	}
	else {
		return $cfg->param($configItem);
	}
}

########################################
#Check if port is available            #
########################################
sub isPortAvailable {

	#Adapted from ikegami's example on http://www.perlmonks.org/?node_id=759131
	#1 is available, 0 is in use
	my $family = PF_INET;
	my $type   = SOCK_STREAM;
	my $proto  = getprotobyname('tcp')
	  or $log->logdie("Failed at getprotobyname: $!");
	my $host = INADDR_ANY;    # Use inet_aton for a specific interface
	my $port;
	my $name;

	$port = $_[0];

	socket( my $sock, $family, $type, $proto )
	  or $log->logdie("Unable to get socket: $!");
	$name = sockaddr_in( $port, $host )
	  or $log->logdie("Unable to get sockaddr_in: $!");

	bind( $sock, $name ) and return 1;
	$! == EADDRINUSE and return 0;
	return $!;
	$log->logdie("While checking for available port bind failed: $!");
}

########################################
#Check configured port                 #
########################################
sub checkConfiguredPort {
	my $cfg;
	my $configItem;
	my $availCode;
	my $configValue;
	my $input;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");
	$configItem = $_[0];
	if ( defined( $_[1] ) ) {
		$cfg = $_[1];
		$log->debug("Config has been passed to $subname.");
	}
	else {
		$cfg = $globalConfig;
		$log->debug(
			"Config has not been passed to function, using global config.");
	}

	my $LOOP = 1;
	while ( $LOOP == 1 ) {
		$configValue = $cfg->param($configItem);
		if ( !defined($configValue) ) {
			$log->logdie(
"No port has been configured for the config item '$configItem'. Please enter a configuration value and try again. This script will now exit."
			);
		}
		elsif ( $configValue eq "" ) {
			genConfigItem(
				"UPDATE",
				$cfg,
				$configItem,
"No port number has been entered. Please enter the new port number for $configItem",
				""
			);
		}
		else {
			$availCode = isPortAvailable($configValue);
			dumpSingleVarToLog(
				"Port $configValue availability: $availCode (1=AVAIL/0=INUSE)",
				$availCode
			);

			if ( $availCode == 1 ) {
				$log->debug("Port is available.");
				$LOOP = 0;
			}
			else {
				$log->debug("Port is in use.");

				print
"The port you have configured ($configValue) for $configItem is currently in use, this may be expected if you are already running the application."
				  . "\nOtherwise you may need to configure another port.\n\nWould you like to configure a different port? yes/no [yes]: ";
				$input = getBooleanInput();
				print "\n";
				if (   $input eq "yes"
					|| $input eq "default" )
				{
					$log->debug("User selected to configure new port.");
					genConfigItem( "UPDATE", $cfg, $configItem,
						"Please enter the new port number to configure", "" );

				}
				elsif ( $input eq "no" ) {
					$LOOP = 0;
					$log->debug("User selected to keep existing port.");
				}
			}
		}
	}
}

########################################
#BackupDirectoryAndChown               #
#NOTE This will MOVE to a backup, not  #
#copy...                               #
########################################
sub backupDirectoryAndChown {
	my $date = strftime "%Y%m%d_%H%M%S", localtime;
	my $originalDir;
	my $osUser;
	my $backupDirName;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	$originalDir = $_[0];
	$osUser      = $_[1];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_originalDir", $originalDir );
	dumpSingleVarToLog( "$subname" . "_osUser",      $osUser );
	dumpSingleVarToLog( "$subname" . "_date",        $date );

	$backupDirName = $originalDir . "_backup_" . $date;
	$log->info("$subname: Backing up $originalDir to $backupDirName");

	moveDirectory( $originalDir, $backupDirName );
	print "Folder moved to " . $backupDirName . "\n\n";
	$log->debug("$subname: Doing recursive chown of $backupDirName to $osUser");
	chownRecursive( $osUser, $backupDirName );
}

########################################
#getUserUidGid                         #
########################################
sub getUserUidGid {
	my $osUser;
	my $login;
	my $pass;
	my $uid;
	my $gid;
	my @return;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	$osUser = $_[0];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_osUser", $osUser );

	( $login, $pass, $uid, $gid ) = getpwnam($osUser)
	  or $log->logdie("$osUser not in passwd file");

	@return = ( $uid, $gid );
	dumpSingleVarToLog( "$subname" . "_uid", $uid );
	dumpSingleVarToLog( "$subname" . "_gid", $gid );
	return @return;
}

########################################
#ChownRecursive                        #
########################################
sub chownRecursive {
	my $directory;
	my $osUser;
	my @uidGid;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	$osUser    = $_[0];
	$directory = $_[1];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_osUser",    $osUser );
	dumpSingleVarToLog( "$subname" . "_directory", $directory );

	#Get UID and GID for the user
	@uidGid = getUserUidGid($osUser);

	print "Chowning files to correct user. Please wait.\n\n";
	$log->info("CHOWNING: $directory");

	find(
		sub {
			$log->trace("CHOWNING: $_");
			chown $uidGid[0], $uidGid[1], $_
			  or $log->logdie("could not chown '$_': $!");
		},
		$directory
	);

	print "Files chowned successfully.\n\n";
}

########################################
#ChownFile                             #
########################################
sub chownFile {
	my $osUser;
	my @uidGid;
	my $file;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	$osUser = $_[0];
	$file   = $_[1];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_osUser", $osUser );
	dumpSingleVarToLog( "$subname" . "_file",   $file );

	#Get UID and GID for the user
	@uidGid = getUserUidGid($osUser);

	print "Chowning file to correct user. Please wait.\n\n";

	$log->debug("CHOWNING: $file");
	chown $uidGid[0], $uidGid[1], $file
	  or $log->logdie("could not chown '$_': $!");

	print "File chowned successfully.\n\n";
}

########################################
#CreateOSUser                           #
########################################
sub createOSUser {
	my $osUser;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	$osUser = $_[0];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_osUser", $osUser );

	if ( !getpwnam($osUser) ) {
		system("useradd $osUser");
		if ( $? == -1 ) {
			$log->logdie("could not create system user $osUser");
		}
		else {
			$log->info("System user $osUser added successfully.");
		}
	}
	else {
		$log->info("System user $osUser already exists.");
	}
}

########################################
#Generate Jira Kickstart File          #
########################################
sub generateJiraKickstart {
	my $filename;    #Must contain absolute path
	my $mode;        #"INSTALL" or "UPGRADE"
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	$filename = $_[0];
	$mode     = $_[1];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_filename", $filename );
	dumpSingleVarToLog( "$subname" . "_mode",     $mode );

	open FH, ">$filename"
	  or $log->logdie("Unable to open $filename for writing.");
	print FH "#install4j response file for JIRA\n";
	if ( $mode eq "UPGRADE" ) {
		print FH 'backupJira$Boolean=true\n';
	}
	if ( $mode eq "INSTALL" ) {
		print FH 'rmiPort$Long='
		  . $globalConfig->param("jira.serverPort") . "\n";
		print FH "app.jiraHome=" . $globalConfig->param("jira.dataDir") . "\n";
	}
	if ( $globalConfig->param("jira.runAsService") eq "TRUE" ) {
		print FH 'app.install.service$Boolean=true' . "\n";
	}
	else {
		print FH 'app.install.service$Boolean=false' . "\n";
	}
	print FH "existingInstallationDir="
	  . $globalConfig->param("jira.installDir") . "\n";

	if ( $mode eq "UPGRADE" ) {
		print FH "sys.confirmedUpdateInstallationString=true" . "\n";
	}
	else {
		print FH "sys.confirmedUpdateInstallationString=false" . "\n";
	}
	print FH "sys.languageId=en" . "\n";
	if ( $mode eq "INSTALL" ) {
		print FH "sys.installationDir="
		  . $globalConfig->param("jira.installDir") . "\n";
	}
	print FH 'executeLauncherAction$Boolean=true' . "\n";
	if ( $mode eq "INSTALL" ) {
		print FH 'httpPort$Long='
		  . $globalConfig->param("jira.connectorPort") . "\n";
		print FH "portChoice=custom" . "\n";
	}

	close FH;

}

########################################
#Generate Generic Kickstart File       #
########################################
sub generateGenericKickstart {
	my $filename;    #Must contain absolute path
	my $mode;        #"INSTALL" or "UPGRADE"
	my $application;
	my $lcApplication;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	$filename      = $_[0];
	$mode          = $_[1];
	$application   = $_[2];
	$lcApplication = lc($application);

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_filename",      $filename );
	dumpSingleVarToLog( "$subname" . "_mode",          $mode );
	dumpSingleVarToLog( "$subname" . "_application",   $application );
	dumpSingleVarToLog( "$subname" . "_lcApplication", $lcApplication );

	open FH, ">$filename"
	  or $log->logdie("Unable to open $filename for writing.");
	print FH "#install4j response file for $application\n";
	if ( $mode eq "UPGRADE" ) {
		print FH 'backup' . $application . '$Boolean=true\n';
	}
	if ( $mode eq "INSTALL" ) {
		print FH 'rmiPort$Long='
		  . $globalConfig->param( $lcApplication . ".serverPort" ) . "\n";
		print FH "app.confHome="
		  . $globalConfig->param( $lcApplication . ".dataDir" ) . "\n";
	}
	if ( $globalConfig->param( $lcApplication . ".runAsService" ) eq "TRUE" ) {
		print FH 'app.install.service$Boolean=true' . "\n";
	}
	else {
		print FH 'app.install.service$Boolean=false' . "\n";
	}
	print FH "existingInstallationDir="
	  . $globalConfig->param( $lcApplication . ".installDir" ) . "\n";

	if ( $mode eq "UPGRADE" ) {
		print FH "sys.confirmedUpdateInstallationString=true" . "\n";
	}
	else {
		print FH "sys.confirmedUpdateInstallationString=false" . "\n";
	}
	print FH "sys.languageId=en" . "\n";
	if ( $mode eq "INSTALL" ) {
		print FH "sys.installationDir="
		  . $globalConfig->param( $lcApplication . ".installDir" ) . "\n";
	}
	print FH 'executeLauncherAction$Boolean=true' . "\n";
	if ( $mode eq "INSTALL" ) {
		print FH 'httpPort$Long='
		  . $globalConfig->param( $lcApplication . ".connectorPort" ) . "\n";
		print FH "portChoice=custom" . "\n";
	}

	close FH;

}

########################################
#downloadJDBCConnector                 #
########################################
sub downloadJDBCConnector {
	my $dbType;
	my $input;
	my $LOOP = 1;
	my $downloadResponseCode;
	my $parsedURL;
	my $archiveFile;
	my $url;
	my $jarFile;
	my $ae;
	my $cfg;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	$dbType = $_[0];
	$cfg    = $_[1];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_dbType", $dbType );

	print
"Not all the Atlassian products come with the $dbType connector so we need to download it.\n\n";
	if ( $dbType eq "MySQL" ) {
		print
"In a web browser please visit http://dev.mysql.com/downloads/connector/j/ and note down the version number (such as 5.2.22).\n";
		print "Enter the version number displayed on the page above: ";
		while ( $LOOP == 1 ) {
			$input = getGenericInput();
			$log->info("MYSQL JDBC version number entered: $input");
			if ( $input eq "default" ) {
				$log->info("MYSQL JDBC null version entered.");
				print
"You did not enter anything, please enter a valid version number: ";
			}
			else {
				$log->info( "MYSQL JDBC version number entered - $subname"
					  . "_input: $input" );
				$url =
"http://cdn.mysql.com/Downloads/Connector-J/mysql-connector-java-"
				  . $input
				  . ".tar.gz";
				dumpSingleVarToLog( "$subname" . "_url", $url );
				if ( head($url) ) {
					$log->info("MSQL JDBC Version entered $input is valid");
					$LOOP = 0;
				}
				else {
					$log->info("MSQL JDBC Version entered $input not valid");
					print
"That is not a valid version, no such URL with that version exists. Please try again: ";
				}
			}
		}

	}

	#Parse the URL so that we can get specific sections of it
	$parsedURL = URI->new($url);
	my @bits = $parsedURL->path_segments();

	#Set the download to show progress as we download
	$ua->show_progress(1);

	$archiveFile = $Bin . "/" . $bits[ @bits - 1 ];
	dumpSingleVarToLog( "$subname" . "_archiveFile", $archiveFile );
	print "Downloading JDBC connector for $dbType...\n\n";
	$downloadResponseCode = getstore( $url, $archiveFile );
	dumpSingleVarToLog( "$subname" . "_downloadResponseCode",
		$downloadResponseCode );

#Test if the download was a success, if not die and return HTTP response code otherwise return the absolute path to file
	if ( is_success($downloadResponseCode) ) {
		print "\n";
		print "Download completed successfully.\n\n";
		$log->info("JDBC download succeeded.");
	}
	else {
		$log->logdie(
"Could not download $input. HTTP Response received was: '$downloadResponseCode'"
		);
	}

	if ( $dbType eq "MySQL" ) {

		#Make sure file exists
		if ( !-e $archiveFile ) {
			$log->logdie(
"File $archiveFile could not be extracted. File does not exist.\n\n"
			);
		}

		#Set up extract object
		$ae = Archive::Extract->new( archive => $archiveFile );
		print "Extracting $archiveFile. Please wait...\n\n";
		$log->info("Extracting $archiveFile.");

		#Extract
		$ae->extract( to => $Bin );
		if ( $ae->error ) {
			$log->logdie(
"Unable to extract $archiveFile. The following error was encountered: $ae->error\n\n"
			);
		}

		print "Extracting $archiveFile has been completed.\n\n";
		$log->info("Extract completed successfully.");

		$jarFile = $ae->extract_path() . "/mysql-connector-java-$input-bin.jar";
		dumpSingleVarToLog( "$subname" . "_jarFile", $jarFile );
		if ( -e $jarFile ) {
			$cfg->param( "general.dbJDBCJar", $jarFile );
			$log->info("Writing out config file to disk.");
			$cfg->write($configFile);
		}
		else {
			$log->logdie(
"Unable to locate the $dbType Jar file automagically ($jarFile does not exist)\nPlease locate the file and update '$configFile' and set general->dbJDBCJar to the absolute path manually."
			);
		}

	}
}

########################################
#findDistro                            #
########################################
sub findDistro {
	my $distribution;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	#Test for debian
	if ( -e "/etc/debian_version" ) {
		$log->info("OS is Debian");
		$distribution = "debian";
	}

	#Test for redhat
	elsif ( -f "/etc/redhat-release" ) {
		$log->info("OS is Redhat");
		$distribution = "redhat";
	}

	#Otherwise distro not supported
	else {
		$log->info("OS is unknown");
		$distribution = "unknown";
	}

	return $distribution;
}

########################################
#generateApplicationConfig             #
########################################
sub generateApplicationConfig {
	my $application;
	my $lcApplication;
	my $mode;
	my $cfg;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	$application   = $_[0];
	$mode          = $_[1];
	$cfg           = $_[2];
	$lcApplication = lc($application);

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_mode",          $mode );
	dumpSingleVarToLog( "$subname" . "_application",   $application );
	dumpSingleVarToLog( "$subname" . "_lcApplication", $lcApplication );

	if ( $lcApplication eq "jira" ) {
		generateJiraConfig( $mode, $cfg );
	}
	elsif ( $lcApplication eq "confluence" ) {
		generateConfluenceConfig( $mode, $cfg );
	}
	elsif ( $lcApplication eq "crowd" ) {
		generateCrowdConfig( $mode, $cfg );
	}
	elsif ( $lcApplication eq "fisheye" ) {
		generateFisheyeConfig( $mode, $cfg );
	}
	elsif ( $lcApplication eq "bamboo" ) {
		generateBambooConfig( $mode, $cfg );
	}
	elsif ( $lcApplication eq "stash" ) {
		generateCrowdConfig( $mode, $cfg );
	}
	elsif ( $lcApplication eq "bamboo" ) {
		generateBambooConfig( $mode, $cfg );
	}

	$log->info("Writing out config file to disk.");
	$cfg->write($configFile);
	loadSuiteConfig();
}

########################################
#createAndChownDirectory               #
########################################
sub createAndChownDirectory {
	my $directory;
	my $osUser;
	my @uidGid;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	$directory = $_[0];
	$osUser    = $_[1];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_directory", $directory );
	dumpSingleVarToLog( "$subname" . "_osUser",    $osUser );

	#Get UID and GID for the user
	@uidGid = getUserUidGid($osUser);

	#Check if the directory exists if so just chown it
	if ( -d $directory ) {
		$log->info("Directory $directory exists, just chowning.");
		print "Directory exists...\n\n";
		chownRecursive( $osUser, $directory );
	}

#If the directory doesn't exist make the path to the directory (including any missing folders)
	else {
		$log->info(
			"Directory $directory does not exist, creating and chowning.");
		print "Directory does not exist, creating...\n\n";
		make_path(
			$directory,
			{
				verbose => 1,
				mode    => 0755,
			}
		);

		#Then chown the directory recursively
		print "Chowning files for good measure...\n\n";
		chownRecursive( $osUser, $directory );
	}
}

########################################
#createDirectory                       #
########################################
sub createDirectory {
	my $directory;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	$directory = $_[0];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_directory", $directory );

	#If the directory does not exist... create it
	if ( !-d $directory ) {
		$log->debug("Directory $directory does not exist, creating.");
		print "Directory does not exist, creating...\n\n";
		make_path(
			$directory,
			{
				verbose => 1,
				mode    => 0755,
			}
		);
	}
}

########################################
#MoveDirectory                         #
########################################
sub moveDirectory {
	my $origDirectory;
	my $newDirectory;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	$origDirectory = $_[0];
	$newDirectory  = $_[1];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_origDirectory", $origDirectory );
	dumpSingleVarToLog( "$subname" . "_newDirectory",  $newDirectory );

	$log->info("$subname: Moving $origDirectory to $newDirectory.");

	if ( move( $origDirectory, $newDirectory ) == 0 ) {
		$log->logdie(
"Unable to move folder $origDirectory to $newDirectory. Unknown error occured.\n\n"
		);
	}

}

########################################
#CopyDirectory                         #
########################################
sub copyDirectory {
	my $origDirectory;
	my $newDirectory;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	$origDirectory = $_[0];
	$newDirectory  = $_[1];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_origDirectory", $origDirectory );
	dumpSingleVarToLog( "$subname" . "_newDirectory",  $newDirectory );

	$log->info("$subname: Copying $origDirectory to $newDirectory.");

	if ( copy( $origDirectory, $newDirectory ) == 0 ) {
		$log->logdie(
"Unable to copy folder $origDirectory to $newDirectory. Unknown error occured.\n\n"
		);
	}

}

########################################
#CheckRequiredConfigItems              #
########################################
sub checkRequiredConfigItems {
	my @requiredConfigItems;
	my @parameterNull;
	my $failureCount = 0;
	my $subname      = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	@requiredConfigItems = @_;

	foreach (@requiredConfigItems) {

		#$_;
		@parameterNull = $globalConfig->param($_);
		if ( ( $#parameterNull == -1 ) || $globalConfig->param($_) eq "" ) {
			$failureCount++;
		}
	}

	$log->info("Failure count of required config items: $failureCount");
	if ( $failureCount > 0 ) {
		return "FAIL";
	}
	else {
		return "PASS";
	}

}

########################################
#Manage Service                        #
########################################
sub manageService {
	my $application;
	my $mode;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	$application = $_[0];
	$mode        = $_[1];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_application", $application );
	dumpSingleVarToLog( "$subname" . "_mode",        $mode );

	#Install the service
	if ( $mode eq "INSTALL" ) {
		$log->info("Installing Service for $application.");
		print "Installing Service for $application...\n\n";
		if ( $distro eq "redhat" ) {
			system("chkconfig --add $application") == 0
			  or $log->logdie("Adding $application as a service failed: $?");
		}
		elsif ( $distro eq "debian" ) {
			system("update-rc.d $application defaults") == 0
			  or $log->logdie("Adding $application as a service failed: $?");
		}
		print "Service installed successfully...\n\n";
	}

	#Remove the service
	elsif ( $mode eq "UNINSTALL" ) {
		$log->info("Removing Service for $application.");
		print "Removing Service for $application...\n\n";
		if ( $distro eq "redhat" ) {
			system("chkconfig --del $application") == 0
			  or $log->logdie("Removing $application as a service failed: $?");
		}
		elsif ( $distro eq "debian" ) {
			system("update-rc.d -f $application remove") == 0
			  or $log->logdie("Removing $application as a service failed: $?");

		}
		print "Service removed successfully...\n\n";
	}

}

########################################
#WhichApplicationArchitecture          #
########################################
sub whichApplicationArchitecture {
	if ( testOSArchitecture() eq "64" ) {
		if ( $globalConfig->param("general.force32Bit") eq "TRUE" ) {
			return "32";
		}
		else {
			return "64";
		}
	}
	else {
		return "64";
	}
}

########################################
#BootStrapper                          #
########################################
sub bootStrapper {
	my @parameterNull;
	my @requiredConfigItems;
	my $input;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	#Check for supported distribution of *nix
	$distro = findDistro();

#If distro unknown die as not supported (if you receive this in error please log a bug to me)
	if ( $distro eq "unknown" ) {
		$log->logdie(
"This operating system is currently unsupported. Only Redhat (and derivatives) and Debian (and derivatives) currently supported.\n\n"
		);
	}

	#Try to load configuration file
	loadSuiteConfig();

	#If no config found, force generation
	if ( !$globalConfig ) {
		$log->info("No config file found, forcing global config generation.");
		generateSuiteConfig();
	}

 #If config file exists check for required config items.
 #Useful if new functions have been added to ensure new config items are defined
	else {
		@requiredConfigItems = (
			"general.rootDataDir",  "general.rootInstallDir",
			"general.targetDBType", "general.force32Bit"
		);
		if ( checkRequiredConfigItems(@requiredConfigItems) eq "FAIL" ) {
			$log->info(
				"Some config items missing, kicking off config generation");
			print
"There are some global configuration items that are incomplete or missing. This may be due to new features or new config items.\n\nThe global config manager will now run to get all items, please press return/enter to begin.\n\n";
			$input = <STDIN>;
			generateSuiteConfig();
		}

	  #Check for database setting that requires a JDBC Jar file to be downloaded
	  #to ensure this is done, we die if the parameter is not defined.
		else {
			@parameterNull = $globalConfig->param("general.dbJDBCJar");
			if (
				(
					   $globalConfig->param("general.targetDBType") eq "Oracle"
					|| $globalConfig->param("general.targetDBType") eq "MSSQL"
				) & (
					( $#parameterNull == -1 )
					  || $globalConfig->param("general.dbJDBCJar") eq ""
				)
			  )
			{
				print
"In order to continue you must download the JDBC JAR file for "
				  . $globalConfig->param("general.targetDBType")
				  . " and edit $configFile and add the absolute path to the jar file in [general]-->dbJDBCJar.\n\n";
				$log->logdie(
					"JAR PARAM is NULL. This script will now exit.\n\n");
			}
			elsif (
				(
					   $globalConfig->param("general.targetDBType") eq "MySQL"
					|| $globalConfig->param("general.targetDBType") eq
					"PostgreSQL"
				) & (
					( $#parameterNull == -1 )
					  || $globalConfig->param("general.dbJDBCJar") eq ""
				)
			  )
			{
				print
"In order to continue you must download the JDBC JAR file for "
				  . $globalConfig->param("general.targetDBType")
				  . " and edit $configFile and add the absolute path to the jar file in [general]-->dbJDBCJar.\n\n";
				$log->logdie(
					"JAR PARAM is NULL. This script will now exit.\n\n");
			}
		}
	}

	#Set the architecture once on startup
	$globalArch = whichApplicationArchitecture();

	my $help                = '';    #commandOption
	my $gen_config          = '';    #commandOption
	my $install_crowd       = 0;     #commandOption
	my $install_jira        = 0;     #commandOption
	my $install_confluence  = 0;     #commandOption
	my $install_fisheye     = 0;     #commandOption
	my $install_bamboo      = 0;     #commandOption
	my $install_stash       = 0;     #commandOption
	my $upgrade_crowd       = 0;     #commandOption
	my $upgrade_jira        = 0;     #commandOption
	my $upgrade_confluence  = 0;     #commandOption
	my $upgrade_fisheye     = 0;     #commandOption
	my $upgrade_bamboo      = 0;     #commandOption
	my $upgrade_stash       = 0;     #commandOption
	my $tar_crowd_logs      = '';    #commandOption
	my $tar_confluence_logs = '';    #commandOption
	my $tar_jira_logs       = '';    #commandOption
	my $tar_fisheye_logs    = '';    #commandOption
	my $tar_bamboo_logs     = '';    #commandOption
	my $tar_stash_logs      = '';    #commandOption
	my $disable_service     = '';    #commandOption
	my $enable_service      = '';    #commandOption
	my $check_service       = '';    #commandOption
	my $update_sh_script    = '';    #commandOption
	my $verify_config       = '';    #commandOption

	GetOptions( 'help|h+'                    => \$help );
	GetOptions( 'gen-config+'                => \$gen_config );
	GetOptions( 'install-crowd+'             => \$install_crowd );
	GetOptions( 'install-confluence+'        => \$install_confluence );
	GetOptions( 'install-jira+'              => \$install_jira );
	GetOptions( 'install-fisheye+'           => \$install_fisheye );
	GetOptions( 'install-stash+'             => \$install_stash );
	GetOptions( 'install-bamboo+'            => \$install_bamboo );
	GetOptions( 'upgrade-crowd+'             => \$upgrade_crowd );
	GetOptions( 'upgrade-confluence+'        => \$upgrade_confluence );
	GetOptions( 'upgrade-jira+'              => \$upgrade_jira );
	GetOptions( 'upgrade-fisheye+'           => \$upgrade_fisheye );
	GetOptions( 'upgrade-bamboo+'            => \$upgrade_bamboo );
	GetOptions( 'upgrade-stash+'             => \$upgrade_stash );
	GetOptions( 'tar-crowd-logs+'            => \$tar_crowd_logs );
	GetOptions( 'tar-confluence-logs+'       => \$tar_confluence_logs );
	GetOptions( 'tar-jira-logs+'             => \$tar_jira_logs );
	GetOptions( 'tar-fisheye-logs+'          => \$tar_fisheye_logs );
	GetOptions( 'tar-bamboo-logs+'           => \$tar_bamboo_logs );
	GetOptions( 'tar-stash-logs+'            => \$tar_stash_logs );
	GetOptions( 'disable-service=s'          => \$disable_service );
	GetOptions( 'enable-service=s'           => \$enable_service );
	GetOptions( 'check-service=s'            => \$check_service );
	GetOptions( 'update-sh-script+'          => \$update_sh_script );
	GetOptions( 'verify-config+'             => \$update_sh_script );
	GetOptions( 'silent|s+'                  => \$silent );
	GetOptions( 'debug|d+'                   => \$debug );
	GetOptions( 'unsupported|u+'             => \$unsupported );
	GetOptions( 'ignore-version-warnings|i+' => \$ignore_version_warnings );
	GetOptions( 'disable-config-checks|c+'   => \$disable_config_checks );
	GetOptions( 'verbose|v+'                 => \$verbose );

	my $options_count = 0;

#check to ensure if any of the install or upgrade options are used that only one is used at a time
	$options_count =
	  $options_count +
	  $install_crowd +
	  $install_confluence +
	  $install_jira +
	  $install_fisheye +
	  $install_bamboo +
	  $install_stash +
	  $upgrade_crowd +
	  $upgrade_confluence +
	  $upgrade_jira +
	  $upgrade_fisheye +
	  $upgrade_bamboo +
	  $upgrade_stash;

	#logging needs to be added here. As this is only structs leaving till later.
	if ( $options_count > 1 ) {

#print out that you can only use one of the install or upgrade commands at a time
	}
	elsif (
		$options_count == 1    #&&    checkAllOtherOptions
	  )
	{

#print out that you can only use one of the install or upgrade commands at a time without any other command line parameters, proceed but ignore the others
	}
	elsif ( $options_count == 1 ) {

#print out that you can only use one of the install or upgrade commands at a time
	}
	else {

		#processTheRemainingCommandLineParams
	}

}

########################################
#Get the latest URL to download XXX    #
########################################
sub getLatestDownloadURL {
	my $product;
	my $architecture;
	my @returnArray;
	my $decoded_json;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	$product      = $_[0];
	$architecture = $_[1];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_product",      $product );
	dumpSingleVarToLog( "$subname" . "_architecture", $architecture );

	#Build URL to check latest version for a particular product
	my $versionurl =
	  "https://my.atlassian.com/download/feeds/current/" . $product . ".json";
	dumpSingleVarToLog( "$subname" . "_versionurl", $versionurl );
	my $searchString;

 #For each product define the file type that we are looking for in the json feed
	if ( $product eq "confluence" ) {
		$searchString = ".*Linux.*$architecture.*";
	}
	elsif ( $product eq "jira" ) {
		$searchString = ".*Linux.*$architecture.*";
	}
	elsif ( $product eq "stash" ) {
		$searchString = ".*TAR.*";
	}
	elsif ( $product eq "fisheye" ) {
		$searchString = ".*FishEye.*";
	}
	elsif ( $product eq "crowd" ) {
		$searchString = ".*TAR.*";
	}
	elsif ( $product eq "bamboo" ) {
		$searchString = ".*TAR\.GZ.*";
	}
	else {
		print
"That package is not recognised - Really you should never get here so if you managed to *wavesHi*";
		exit 2;
	}

	dumpSingleVarToLog( "$subname" . "_searchString", $searchString );

	#Try and download the feed
	my $json = get($versionurl);
	$log->logdie("JSON Download: Could not get $versionurl!")
	  unless defined $json;

 #We have to rework the string slightly as Atlassian is not returning valid JSON
	$json = substr( $json, 10, -1 );
	$json = '{ "downloads": ' . $json . '}';

	# Decode the entire JSON
	$decoded_json = decode_json($json);

	#Loop through the feed and find the specific file we want for this product
	for my $item ( @{ $decoded_json->{downloads} } ) {
		foreach ( $item->{description} ) {
			if (/$searchString/) {
				@returnArray = ( $item->{zipUrl}, $item->{version} );
				dumpSingleVarToLog( "$subname" . "_zipUrl",  $item->{zipUrl} );
				dumpSingleVarToLog( "$subname" . "_version", $item->{version} );
				return @returnArray;
			}
		}
	}
}

########################################
#Get specific version URL to download  #
########################################
sub getVersionDownloadURL {
	my $product;
	my $architecture;
	my $filename;
	my $fileExt;
	my $version;
	my @returnArray;
	my $versionurl;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	$product      = $_[0];
	$architecture = $_[1];
	$version      = $_[2];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_product",      $product );
	dumpSingleVarToLog( "$subname" . "_architecture", $architecture );
	dumpSingleVarToLog( "$subname" . "_version",      $version );

	#Generate product specific URL
	$versionurl =
	  "http://www.atlassian.com/software/" . $product . "/downloads/binary";
	dumpSingleVarToLog( "$subname" . "_versionurl", $versionurl );

#For each product generate the file name based on known information and input data
	if ( $product eq "confluence" ) {
		$fileExt = "bin";
		$filename =
		    "atlassian-confluence-" 
		  . $version . "-x"
		  . $architecture . "."
		  . $fileExt;
	}
	elsif ( $product eq "jira" ) {
		$fileExt = "bin";
		$filename =
		  "atlassian-jira-" . $version . "-x" . $architecture . "." . $fileExt;
	}
	elsif ( $product eq "stash" ) {
		$fileExt  = "tar.gz";
		$filename = "atlassian-stash-" . $version . "." . $fileExt;
	}
	elsif ( $product eq "fisheye" ) {
		$fileExt  = "zip";
		$filename = "fisheye-" . $version . "." . $fileExt;
	}
	elsif ( $product eq "crowd" ) {
		$fileExt  = "tar.gz";
		$filename = "atlassian-crowd-" . $version . "." . $fileExt;
	}
	elsif ( $product eq "bamboo" ) {
		$fileExt  = "tar.gz";
		$filename = "atlassian-bamboo-" . $version . "." . $fileExt;
	}
	else {
		print
"That package is not recognised - Really you should never get here so if you managed to *wavesHi*";
		exit 2;
	}

	dumpSingleVarToLog( "$subname" . "_fileExt",  $fileExt );
	dumpSingleVarToLog( "$subname" . "_filename", $filename );

	#Return the absolute URL to the version specific download
	@returnArray = ( $versionurl . "/" . $filename, $version );
}

########################################
#GetBooleanInput                       #
########################################
sub getBooleanInput {
	my $LOOP = 1;
	my $input;
	my $subname = ( caller(0) )[3];

	$log->trace("BEGIN: $subname")
	  ;    #we only want this on trace or it makes the script unusable

	while ( $LOOP == 1 ) {

		$input = <STDIN>;
		print "\n";
		chomp $input;
		dumpSingleVarToLog( "$subname" . "_inputEntered", $input );

		if (   ( lc $input ) eq "yes"
			|| ( lc $input ) eq "y" )
		{
			$LOOP = 0;
			return "yes";
		}
		elsif ( ( lc $input ) eq "no" || ( lc $input ) eq "n" ) {
			$LOOP = 0;
			return "no";
		}
		elsif ( $input eq "" ) {
			$LOOP = 0;
			return "default";
		}
		else {
			$log->info(
				"$subname: Input not recognised, asking user for input again.");
			print "Your input '" . $input
			  . "'was not recognised. Please try again and write yes or no.\n";
		}
	}
}

########################################
#getGenericInput                       #
########################################
sub getGenericInput {
	my $input;
	my $subname = ( caller(0) )[3];

	$log->trace("BEGIN: $subname")
	  ;    #we only want this on trace or the script becomes unusable

	$input = <STDIN>;
	print "\n";
	chomp $input;
	dumpSingleVarToLog( "$subname" . "_inputEntered", $input );

	if ( $input eq "" ) {
		$log->debug("$subname: Input entered was null, returning 'default'.");
		return "default";
	}
	else {
		return $input;
	}
}

########################################
#extractAndMoveDownload                #
########################################
sub extractAndMoveDownload {
	my $inputFile;
	my $expectedFolderName;    #MustBeAbsolute
	my $date = strftime "%Y%m%d_%H%M%S", localtime;
	my $osUser;
	my @uidGid;
	my $upgrade;
	my $mode;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	$inputFile          = $_[0];
	$expectedFolderName = $_[1];    #MustBeAbsolute
	$osUser             = $_[2];
	$mode               = $_[3];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_inputFile", $inputFile );
	dumpSingleVarToLog( "$subname" . "_expectedFolderName",
		$expectedFolderName );
	dumpSingleVarToLog( "$subname" . "_osUser", $osUser );
	dumpSingleVarToLog( "$subname" . "_mode",   $mode );
	dumpSingleVarToLog( "$subname" . "_date",   $date );

	#Get the UID and GID for the user so that we can chown files
	@uidGid = getUserUidGid($osUser);

	print "Preparing to extract $inputFile...\n\n";

	#Make sure directory exists
	createDirectory( $globalConfig->param("general.rootInstallDir") );

	#Make sure file exists
	if ( !-e $inputFile ) {
		$log->logdie(
			"File $inputFile could not be extracted. File does not exist.\n\n");
	}

	#Set up extract object
	my $ae = Archive::Extract->new( archive => $inputFile );

	print "Extracting $inputFile. Please wait...\n\n";
	$log->info("$subname: Extracting $inputFile");

	#Extract
	$ae->extract( to => $globalConfig->param("general.rootInstallDir") );
	if ( $ae->error ) {
		$log->logdie(
"Unable to extract $inputFile. The following error was encountered: $ae->error\n\n"
		);
	}

	print "Extracting $inputFile has been completed.\n\n";
	$log->info("$subname: Extract completed.");

	#Check for existing folder and provide option to backup
	if ( -d $expectedFolderName ) {
		if ( $mode eq "UPGRADE" ) {
			print "Backing up old installation folder to $expectedFolderName"
			  . "_upgrade_"
			  . $date
			  . ", please wait...\n\n";
			moveDirectoryAndChown( $expectedFolderName, $osUser );
		}
		else {
			my $LOOP = 1;
			my $input;
			$log->info("$subname: $expectedFolderName already exists.");
			print "The destination directory '"
			  . $expectedFolderName
			  . " already exists. Would you like to overwrite or create a backup? o=overwrite\\b=backup [b]\n";
			while ( $LOOP == 1 ) {

				$input = <STDIN>;
				chomp $input;
				dumpSingleVarToLog( "$subname" . "_inputEntered", $input );
				print "\n";

				#If user selects, backup existing folder
				if (   ( lc $input ) eq "backup"
					|| ( lc $input ) eq "b"
					|| $input eq "" )
				{
					$log->info("$subname: User opted to backup directory");
					$LOOP = 0;
					moveDirectory( $expectedFolderName,
						$expectedFolderName . $date );
					print "Folder backed up to "
					  . $expectedFolderName
					  . $date . "\n\n";
					$log->info( "$subname: Folder backed up to "
						  . $expectedFolderName
						  . $date );

					$log->info(
"$subname: Moving $ae->extract_path() to $expectedFolderName"
					);
					moveDirectory( $ae->extract_path(), $expectedFolderName );

					$log->info(
						"$subname: Chowning $expectedFolderName to $osUser");
					chownRecursive( $osUser, $expectedFolderName );
				}

#If user selects, overwrite existing folder by deleting and then moving new directory in place
				elsif (( lc $input ) eq "overwrite"
					|| ( lc $input ) eq "o" )
				{
					$log->info("$subname: User opted to overwrite directory");
					$LOOP = 0;

#Considered failure handling for rmtree however based on http://perldoc.perl.org/File/Path.html used
#recommended in built error handling.
					rmtree( ["$expectedFolderName"] );

					$log->info(
"$subname: Moving $ae->extract_path() to $expectedFolderName"
					);
					moveDirectory( $ae->extract_path(), $expectedFolderName );
					$log->info(
						"$subname: Chowning $expectedFolderName to $osUser");
					chownRecursive( $osUser, $expectedFolderName );
				}

				#Input was not recognised, ask user for input again
				else {
					$log->info(
"$subname: User input not recognised, getting input again."
					);
					print "Your input '" . $input
					  . "'was not recognised. Please try again and write either 'B' for backup or 'O' to overwrite [B].\n";
				}
			}
		}
	}

	#Directory does not exist, move new directory in place.
	else {
		$log->info(
			"$subname: Moving $ae->extract_path() to $expectedFolderName");
		moveDirectory( $ae->extract_path(), $expectedFolderName );
		$log->info("$subname: Chowning $expectedFolderName to $osUser");
		chownRecursive( $osUser, $expectedFolderName );
	}

}

########################################
#genConfigItem                         #
########################################
sub genConfigItem {
	my $mode;
	my $cfg;
	my $configParam;
	my $messageText;
	my $defaultInputValue;
	my $defaultValue;
	my $input;
	my @parameterNull;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	$mode              = $_[0];
	$cfg               = $_[1];
	$configParam       = $_[2];
	$messageText       = $_[3];
	$defaultInputValue = $_[4];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_mode",              $mode );
	dumpSingleVarToLog( "$subname" . "_configParam",       $configParam );
	dumpSingleVarToLog( "$subname" . "_messageText",       $messageText );
	dumpSingleVarToLog( "$subname" . "_defaultInputValue", $defaultInputValue );

	#Check if the paramater is null (undefined)
	@parameterNull = $cfg->param($configParam);

#Check if we are updating (get current value), or doing a fresh run (use default passed to this function)
	if ( $mode eq "UPDATE" ) {

		#Check if the current value is defined
		if ( defined( $cfg->param($configParam) ) & !( $#parameterNull == -1 ) )
		{
			$defaultValue = $cfg->param($configParam);
			dumpSingleVarToLog( "$subname" . "_defaultValue", $defaultValue );
		}
		else {
			$defaultValue = $defaultInputValue;
			dumpSingleVarToLog( "$subname" . "_defaultValue", $defaultValue );
		}
	}
	else {
		$defaultValue = $defaultInputValue;
		dumpSingleVarToLog( "$subname" . "_defaultValue", $defaultValue );
	}
	print $messageText . " [" . $defaultValue . "]: ";

	$input = getGenericInput();
	print "\n";

#If default option is selected (i.e. just a return), use default value, otherwise use input
	if ( $input eq "default" ) {
		$cfg->param( $configParam, $defaultValue );
		$log->debug(
			"$subname: default selected, setting $configParam to $defaultValue"
		);
	}
	elsif ( lc($input) eq "null" ) {
		$cfg->param( $configParam, "NULL" );
		$log->debug("$subname: NULL input, setting $configParam to 'NULL'");
	}
	else {
		$cfg->param( $configParam, $input );
		$log->debug("$subname: Setting $configParam to '$input'");
	}

}

########################################
#genBooleanConfigItem                  #
########################################
sub genBooleanConfigItem {
	my $mode;
	my $cfg;
	my $configParam;
	my $messageText;
	my $defaultInputValue;
	my $defaultValue;
	my $input;
	my @parameterNull;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	$mode              = $_[0];
	$cfg               = $_[1];
	$configParam       = $_[2];
	$messageText       = $_[3];
	$defaultInputValue = $_[4];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_mode",              $mode );
	dumpSingleVarToLog( "$subname" . "_configParam",       $configParam );
	dumpSingleVarToLog( "$subname" . "_messageText",       $messageText );
	dumpSingleVarToLog( "$subname" . "_defaultInputValue", $defaultInputValue );

	#Check if parameter is null (undefined)
	@parameterNull = $cfg->param($configParam);

#Check if we are updating (get current value), or doing a fresh run (use default passed to this function)
	if ( $mode eq "UPDATE" ) {

		#Check if the current value is defined
		if ( defined( $cfg->param($configParam) ) & !( $#parameterNull == -1 ) )
		{
			if ( $cfg->param($configParam) eq "TRUE" ) {
				$defaultValue = "yes";
				$log->debug(
"$subname: Current parameter $configParam is TRUE, returning 'yes'"
				);
			}
			elsif ( $cfg->param($configParam) eq "FALSE" ) {
				$defaultValue = "no";
				$log->debug(
"$subname: Current parameter $configParam is FALSE, returning 'no'"
				);
			}
		}
		else {
			$log->debug(
"$subname: Current parameter $configParam is undefined, returning '$defaultInputValue'"
			);
			$defaultValue = $defaultInputValue;
		}
	}
	else {
		$log->debug(
"$subname: Current parameter $configParam is undefined, returning '$defaultInputValue'"
		);
		$defaultValue = $defaultInputValue;
	}
	print $messageText . " [" . $defaultValue . "]: ";

	$input = getBooleanInput();
	print "\n";

#If default option is selected (i.e. just a return), use default value, set to boolean value based on return
	if ( $input eq "yes"
		|| ( $input eq "default" && $defaultValue eq "yes" ) )
	{
		$log->debug(
			"$subname: Input entered was 'yes' setting $configParam to 'TRUE'");
		$cfg->param( $configParam, "TRUE" );
	}
	elsif ( $input eq "no"
		|| ( $input eq "default" && $defaultValue eq "no" ) )
	{
		$log->debug(
			"$subname: Input entered was 'no' setting $configParam to 'FALSE'");
		$cfg->param( $configParam, "FALSE" );
	}

}

########################################
#updateXMLAttribute                    #
########################################
sub updateXMLAttribute {

	my $xmlFile;    #Must Be Absolute Path
	my $searchString;
	my $referenceAttribute;
	my $attributeValue;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	$xmlFile            = $_[0];
	$searchString       = $_[1];
	$referenceAttribute = $_[2];
	$attributeValue     = $_[3];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_xmlFile",      $xmlFile );
	dumpSingleVarToLog( "$subname" . "_searchString", $searchString );
	dumpSingleVarToLog( "$subname" . "_referenceAttribute",
		$referenceAttribute );
	dumpSingleVarToLog( "$subname" . "_attributeValue", $attributeValue );

	#Set up new XML object, with "pretty" spacing (i.e. standard spacing)
	my $twig = new XML::Twig( pretty_print => 'indented' );

	#Parse the XML file
	$twig->parsefile($xmlFile);

	#Find the node we are looking for based on the provided search string
	for my $node ( $twig->findnodes($searchString) ) {
		$log->info(
"$subname: Found $searchString in $xmlFile. Setting $referenceAttribute to $attributeValue"
		);

		#Set the node to the new attribute value
		$node->set_att( $referenceAttribute => $attributeValue );
	}

	#Print the new XML tree back to the original file
	$log->info("$subname: Writing out updated xmlFile: $xmlFile.");
	$twig->print_to_file($xmlFile);
}

########################################
#updateJAVAOPTS                        #
########################################
sub updateJavaOpts {
	my $inputFile;    #Must Be Absolute Path
	my $javaOpts;
	my $searchFor;
	my $referenceVariable;
	my @data;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	$inputFile         = $_[0];
	$referenceVariable = $_[1];
	$javaOpts          = $_[2];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_inputFile", $inputFile );
	dumpSingleVarToLog( "$subname" . "_javaOpts",  $javaOpts );

	#Try to open the provided file
	open( FILE, $inputFile ) or $log->logdie("Unable to open file: $inputFile");

	# read file into an array
	@data = <FILE>;

	close(FILE);

	$searchFor = $referenceVariable;

	#Search for the provided string in the file array
	my ($index1) = grep { $data[$_] =~ /^$searchFor.*/ } 0 .. $#data;

#See how many times ATLASMGR_JAVA_OPTS occurs in file, this will be in the existing
#JAVA_OPTS parameter as a variable.
#If it doesn't exist this splits up the string so that we can insert it as a new variable
	my $count = grep( /.*ATLASMGR_JAVA_OPTS.*/, $data[$index1] );
	if ( $count == 0 ) {
		$log->info(
"$subname: ATLASMGR_JAVA_OPTS does not yet exist, splitting string to insert it."
		);
		if ( $data[$index1] =~ /(.*?)\"(.*?)\"(.*?)/ ) {
			my $result1 = $1;
			my $result2 = $2;
			my $result3 = $3;

			if ( substr( $result2, -1, 1 ) eq " " ) {
				$data[$index1] =
				    $result1 . '"' 
				  . $result2
				  . '$ATLASMGR_JAVA_OPTS "'
				  . $result3 . "\n";
			}
			else {
				$data[$index1] =
				    $result1 . '"' 
				  . $result2
				  . ' $ATLASMGR_JAVA_OPTS"'
				  . $result3 . "\n";
			}
		}
	}

#Search for the definition of the variable ATLASMGR_JAVA_OPTS which can be used to add
#additional parameters to the main JAVA_OPTS variable
	$searchFor = "ATLASMGR_JAVA_OPTS=";
	my ($index2) = grep { $data[$_] =~ /^$searchFor.*/ } 0 .. $#data;

#If no result is found insert a new line before the line found above which contains the JAVA_OPTS variable
	if ( !defined($index2) ) {
		$log->info("$subname: ATLASMGR_JAVA_OPTS= not found. Adding it in.");

		splice( @data, $index1, 0,
			"ATLASMGR_JAVA_OPTS=\"" . $javaOpts . "\"\n" );
	}

	#Else update the line to have the new parameters that have been specified
	else {
		$log->info(
"$subname: ATLASMGR_JAVA_OPTS= exists, adding new javaOpts parameters."
		);
		$data[$index2] = "ATLASMGR_JAVA_OPTS=\"" . $javaOpts . "\"\n";
	}

	#Try to open file, output the lines that are in memory and close
	open FILE, ">$inputFile"
	  or $log->logdie("Unable to open file $inputFile $!");
	print FILE @data;
	close FILE;

}

########################################
#updateJavaMemParameter                #
########################################
sub updateJavaMemParameter {
	my $inputFile;    #Must Be Absolute Path
	my $referenceVariable;
	my $referenceParameter;
	my $newValue;
	my $searchFor;
	my @data;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	$inputFile          = $_[0];
	$referenceVariable  = $_[1];    #such as JAVA_OPTS
	$referenceParameter = $_[2];    #such as Xmx, Xms, -XX:MaxPermSize and so on
	$newValue           = $_[3];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_inputFile",         $inputFile );
	dumpSingleVarToLog( "$subname" . "_referenceVariable", $referenceVariable );
	dumpSingleVarToLog( "$subname" . "_referenceParameter",
		$referenceParameter );
	dumpSingleVarToLog( "$subname" . "_newValue", $newValue );

	#Try to open the provided file
	open( FILE, $inputFile ) or $log->logdie("Unable to open file: $inputFile");

	# read file into an array
	@data = <FILE>;

	close(FILE);

	$searchFor = $referenceVariable;

	#Search for the provided string in the file array
	my ($index1) = grep { $data[$_] =~ /^$searchFor.*/ } 0 .. $#data;

	my $count = grep( /.*$referenceParameter.*/, $data[$index1] );
	dumpSingleVarToLog( "$subname" . "_count",          $count );
	dumpSingleVarToLog( "$subname" . " ORIGINAL LINE=", $data[$index1] );

	if ( $count == 1 ) {
		$log->info("$subname: Splitting string to update the memory value.");
		if (
			$data[$index1] =~ /^(.*?)($referenceParameter)(.*?)([a-zA-Z])(.*)/ )
		{
			my $result1 =
			  $1;    #should equal everything before $referenceParameter
			my $result2 = $2;    #should equal $referenceParameter
			my $result3 =
			  $3;    #should equal the memory value we are trying to change
			my $result4 = $4
			  ; #should equal the letter i.e. 'm' of the reference memory attribute
			my $result5 = $5;    #should equal the remainder of the line
			dumpSingleVarToLog( "$subname" . " _result1", $result1 );
			dumpSingleVarToLog( "$subname" . " _result2", $result2 );
			dumpSingleVarToLog( "$subname" . " _result3", $result3 );
			dumpSingleVarToLog( "$subname" . " _result4", $result4 );
			dumpSingleVarToLog( "$subname" . " _result5", $result5 );

			$data[$index1] = $result1 . $result2 . $newValue . $result5 . "\n";
			dumpSingleVarToLog( "$subname" . " _newLine=", $data[$index1] );
		}
	}
	else {
		$log->info(
"$subname: $referenceParameter does not yet exist, splitting string to insert it."
		);
		if ( $data[$index1] =~ /^(.*?=)(['"`])(.*?)(['"`])/ ) {
			my $result1 = $1; #should contain contents of $referenceVariable + =
			my $result2 = $2; #should contain the quote character used
			my $result3 = $3; #should contain the bulk of the current string
			my $result4 = $4; #should contain the quote character used
			dumpSingleVarToLog( "$subname" . " _result1", $result1 );
			dumpSingleVarToLog( "$subname" . " _result2", $result2 );
			dumpSingleVarToLog( "$subname" . " _result3", $result3 );
			dumpSingleVarToLog( "$subname" . " _result4", $result4 );

			if ( substr( $result3, -1, 1 ) eq " " ) {
				$data[$index1] =
				    $result1 
				  . $result2 
				  . $result3
				  . $referenceParameter
				  . $newValue
				  . $result4 . "\n";
			}
			else {
				$data[$index1] =
				    $result1 
				  . $result2 
				  . $result3 . " "
				  . $referenceParameter
				  . $newValue
				  . $result4 . "\n";
			}
		}
	}

	$log->info(
		"$subname: Value updated, outputting new line to file $inputFile.");

	#Try to open file, output the lines that are in memory and close
	open FILE, ">$inputFile"
	  or $log->logdie("Unable to open file $inputFile $!");
	print FILE @data;
	close FILE;

}

########################################
#updateEnvironmentVars                 #
########################################
sub updateEnvironmentVars {
	my $inputFile;    #Must Be Absolute Path
	my $searchFor;
	my @data;
	my $referenceVar;
	my $newValue;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	$inputFile    = $_[0];
	$referenceVar = $_[1];
	$newValue     = $_[2];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_inputFile",    $inputFile );
	dumpSingleVarToLog( "$subname" . "_referenceVar", $referenceVar );
	dumpSingleVarToLog( "$subname" . "_newValue",     $newValue );

	#Try to open the provided file
	open( FILE, $inputFile ) or $log->logdie("Unable to open file: $inputFile");

	# read file into an array
	@data = <FILE>;

	close(FILE);

	#Search for the definition of the provided variable
	$searchFor = "$referenceVar=";
	my ($index2) = grep { $data[$_] =~ /^$searchFor.*/ } 0 .. $#data;

#If no result is found insert a new line before the line found above which contains the JAVA_OPTS variable
	if ( !defined($index2) ) {
		$log->info("$subname: $referenceVar= not found. Adding it in.");

		push( @data, $referenceVar . "=\"" . $newValue . "\"\n" );
	}

	#Else update the line to have the new parameters that have been specified
	else {
		$log->info(
"$subname: $referenceVar= exists, updating to have new value: $newValue."
		);
		$data[$index2] = $referenceVar . "=\"" . $newValue . "\"\n";
	}

	#Try to open file, output the lines that are in memory and close
	open FILE, ">$inputFile"
	  or $log->logdie("Unable to open file $inputFile $!");
	print FILE @data;
	close FILE;

}

########################################
#updateLineInFile                      #
########################################
sub updateLineInFile {
	my $inputFile;    #Must Be Absolute Path
	my $newLine;
	my $lineReference;
	my $searchFor;
	my $lineReference2;
	my @data;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	$inputFile      = $_[0];
	$lineReference  = $_[1];
	$newLine        = $_[2];
	$lineReference2 = $_[3];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_inputFile",      $inputFile );
	dumpSingleVarToLog( "$subname" . "_lineReference",  $lineReference );
	dumpSingleVarToLog( "$subname" . "_newLine",        $newLine );
	dumpSingleVarToLog( "$subname" . "_lineReference2", $lineReference2 );
	open( FILE, $inputFile )
	  or $log->logdie("Unable to open file: $inputFile: $!");

	# read file into an array
	@data = <FILE>;

	close(FILE);

	#Search for reference line
	my ($index1) = grep { $data[$_] =~ /^$lineReference.*/ } 0 .. $#data;

	#If you cant find the first reference try for the second reference
	if ( !defined($index1) ) {
		$log->info("$subname: First search term $lineReference not found.");
		if ( defined($lineReference2) ) {
			$log->info("$subname: Trying to search for $lineReference2.");
			my ($index1) =
			  grep { $data[$_] =~ /^$lineReference2.*/ } 0 .. $#data;
			if ( !defined($index1) ) {
				$log->logdie(
"No line containing \"$lineReference\" found in file $inputFile\n\n"
				);
			}

			#Otherwise replace the line with the new provided line
			else {
				$log->info(
					"$subname: Replacing '$data[$index1]' with $newLine.");
				$data[$index1] = $newLine . "\n";
			}
		}
		else {
			$log->logdie(
"No line containing \"$lineReference\" found in file $inputFile\n\n"
			);
		}
	}
	else {
		$log->info("$subname: Replacing '$data[$index1]' with $newLine.");
		$data[$index1] = $newLine . "\n";
	}

	#Write out the updated file
	open FILE, ">$inputFile"
	  or $log->logdie("Unable to open file: $inputFile: $!");
	print FILE @data;
	close FILE;

}

########################################
#updateLineInBambooWrapperConf         #
#This can be used under certain        #
#circumstances to update lines in the  #
#Bamboo Jetty Wrapper as per the issues#
#defined in [#ATLASMGR-143]            #
########################################
sub updateLineInBambooWrapperConf {
	my $inputFile;    #Must Be Absolute Path
	my $variableReference;
	my $searchFor;
	my $parameterReference;
	my $newValue;
	my @data;
	my $index1;
	my $line;
	my $newLine;
	my $count   = 0;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	$inputFile          = $_[0];
	$variableReference  = $_[1];
	$parameterReference = $_[2];
	$newValue           = $_[3];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_inputFile",         $inputFile );
	dumpSingleVarToLog( "$subname" . "_variableReference", $variableReference );
	dumpSingleVarToLog( "$subname" . "_parameterReference",
		$parameterReference );
	dumpSingleVarToLog( "$subname" . "_newValue", $newValue );
	open( FILE, $inputFile )
	  or $log->logdie("Unable to open file: $inputFile: $!");

	# read file into an array
	@data = <FILE>;

	close(FILE);

	#Search for reference line
	($index1) = grep { $data[$_] =~ /.*$parameterReference.*/ } 0 .. $#data;
	if ( !defined($index1) ) {
		$log->info(
"$subname: Line with $parameterReference not found. Going to add it."
		);

#Find the number of paramaters already existing to get the next number
#This is not ideal however I expect this will be deprecated soon when Bamboo moves off Jetty.
		foreach $line (@data) {
			if ( $line =~ /^$variableReference.*/ ) {
				$count++;
			}
		}

		dumpSingleVarToLog( "$subname" . "_count", $count );

		#Now we know the final ID number find it's index in the file
		($index1) =
		  grep { $data[$_] =~ /^$variableReference$count.*/ } 0 .. $#data;

		dumpSingleVarToLog( "$subname" . "_index1", $index1 );

		$index1++
		  ; #add 1 to the found index as the splice inserts before the index not after
		$count++
		  ;   # add 1 to the count as that is the next value that should be used

		#Splicing the array and inserting a new line
		my $newLine =
		    $variableReference 
		  . $count . "="
		  . $parameterReference
		  . $newValue . "\n";
		dumpSingleVarToLog( "$subname" . "_newLine", $newLine );
		splice( @data, $index1, 0, $newLine );

	}
	else {

		#$log->info("$subname: Replacing '$data[$index1]' with $newLine.");

		if ( $data[$index1] =~
			/^($variableReference)(.*)(=)($parameterReference)(.*)/ )
		{
			my $result1 = $1;    #Should contain $variableReference
			my $result2 = $2;    #Should contain the item ID number we need
			my $result3 = $3;    #Should contain '='
			my $result4 = $4;    #Should contain $parameterReference
			my $result5 =
			  $5;    #Should contain the existing value of the parameter
			dumpSingleVarToLog( "$subname" . " _result1", $result1 );
			dumpSingleVarToLog( "$subname" . " _result2", $result2 );
			dumpSingleVarToLog( "$subname" . " _result3", $result3 );
			dumpSingleVarToLog( "$subname" . " _result4", $result4 );
			dumpSingleVarToLog( "$subname" . " _result5", $result5 );

			dumpSingleVarToLog( "$subname" . " _oldLine", $data[$index1] );
			$newLine =
			  $result1 . $result2 . $result3 . $result4 . $newValue . "\n";
			dumpSingleVarToLog( "$subname" . " _newLine", $newLine );
			$data[$index1] = $newLine;
		}

	}

	#Write out the updated file
	open FILE, ">$inputFile"
	  or $log->logdie("Unable to open file: $inputFile: $!");
	print FILE @data;
	close FILE;

}

########################################
#Compare two versions                  #
#compareTwoVersions("current","new");  #
########################################
sub compareTwoVersions {
	my $version1;
	my $version2;
	my @splitVersion1;
	my @splitVersion2;
	my $count;
	my $majorVersionStatus;
	my $midVersionStatus;
	my $minVersionStatus;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	$version1 = $_[0];
	$version2 = $_[1];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_version1", $version1 );
	dumpSingleVarToLog( "$subname" . "_version2", $version2 );

	@splitVersion1 = split( /\./, $version1 );
	@splitVersion2 = split( /\./, $version2 );

#Iterate through first array and test if the version provided is less than or equal to the second array
	for ( $count = 0 ; $count <= $#splitVersion1 ; $count++ ) {
		if ( $count == 0 ) {
			if ( $splitVersion1[$count] < $splitVersion2[$count] ) {
				$majorVersionStatus = "LESS";
			}
			elsif ( $splitVersion1[$count] == $splitVersion2[$count] ) {
				$majorVersionStatus = "EQUAL";
			}
			elsif ( $splitVersion1[$count] > $splitVersion2[$count] ) {
				$majorVersionStatus = "GREATER";
			}

		}
		elsif ( $count == 1 ) {
			if ( $splitVersion1[$count] < $splitVersion2[$count] ) {
				$midVersionStatus = "LESS";
			}
			elsif ( $splitVersion1[$count] == $splitVersion2[$count] ) {
				$midVersionStatus = "EQUAL";
			}
			elsif ( $splitVersion1[$count] > $splitVersion2[$count] ) {
				$midVersionStatus = "GREATER";
			}
		}
		elsif ( $count == 2 ) {
			if (
				defined( $splitVersion1[$count] ) &
				defined( $splitVersion2[$count] ) )
			{
				if ( $splitVersion1[$count] < $splitVersion2[$count] ) {
					$minVersionStatus = "LESS";
				}
				elsif ( $splitVersion1[$count] == $splitVersion2[$count] ) {
					$minVersionStatus = "EQUAL";
				}
				elsif ( $splitVersion1[$count] > $splitVersion2[$count] ) {
					$minVersionStatus = "GREATER";
				}
			}
			elsif (
				defined( $splitVersion1[$count] ) &
				!defined( $splitVersion2[$count] ) )
			{
				$minVersionStatus = "NEWERNULL";
			}
			elsif ( !defined( $splitVersion1[$count] ) &
				defined( $splitVersion2[$count] ) )
			{
				$minVersionStatus = "CURRENTNULL";
			}
			elsif ( !defined( $splitVersion1[$count] ) &
				!defined( $splitVersion2[$count] ) )
			{
				$minVersionStatus = "BOTHNULL";
			}
		}
	}

	dumpSingleVarToLog( "$subname" . "_majorVersionStatus",
		$majorVersionStatus );
	dumpSingleVarToLog( "$subname" . "_midVersionStatus", $midVersionStatus );
	dumpSingleVarToLog( "$subname" . "_minVersionStatus", $minVersionStatus );

	if ( $majorVersionStatus eq "LESS" ) {
		return "LESS";
	}
	elsif ( $majorVersionStatus eq "GREATER" ) {
		$log->info("$subname: Newer version is greater than old version.");
		return "GREATER";
	}
	elsif ( $majorVersionStatus eq "EQUAL" & $midVersionStatus eq "LESS" ) {
		$log->info("$subname: Newer version is less than old version.");
		return "LESS";
	}
	elsif ( $majorVersionStatus eq "EQUAL" & $midVersionStatus eq "GREATER" ) {
		$log->info("$subname: Newer version is greater than old version.");
		return "GREATER";
	}
	elsif ( $majorVersionStatus eq "EQUAL" & $midVersionStatus eq "EQUAL" &
		!defined($minVersionStatus) )
	{
		$log->info("$subname: Newer version is equal to old version.");
		return "EQUAL";
	}
	elsif ( $majorVersionStatus eq "EQUAL" & $midVersionStatus eq "EQUAL" &
		$minVersionStatus eq "LESS" )
	{
		$log->info("$subname: Newer version is less than old version.");
		return "LESS";
	}
	elsif ( $majorVersionStatus eq "EQUAL" & $midVersionStatus eq "EQUAL" &
		$minVersionStatus eq "GREATER" )
	{
		$log->info("$subname: Newer version is greater than old version.");
		return "GREATER";
	}
	elsif ( $majorVersionStatus eq "EQUAL" & $midVersionStatus eq "EQUAL" &
		$minVersionStatus eq "EQUAL" )
	{
		$log->info("$subname: Newer version is equal to old version.");
		return "EQUAL";
	}
	elsif ( $majorVersionStatus eq "EQUAL" & $midVersionStatus eq "EQUAL" &
		$minVersionStatus eq "NEWERNULL" )
	{
		$log->info("$subname: Newer version is greater than old version.");
		return "GREATER";
	}
	elsif ( $majorVersionStatus eq "EQUAL" & $midVersionStatus eq "EQUAL" &
		$minVersionStatus eq "CURRENTNULL" )
	{
		$log->info("$subname: Newer version is less than old version.");
		return "LESS";
	}
	elsif ( $majorVersionStatus eq "EQUAL" & $midVersionStatus eq "EQUAL" &
		$minVersionStatus eq "BOTHULL" )
	{
		$log->info("$subname: Newer version is equal to old version.");
		return "EQUAL";
	}

}

########################################
#isSupportedVersion                   #
########################################
sub isSupportedVersion {
	my $product;
	my $version;
	my $productVersion;
	my $count;
	my $versionReturn;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	$product = $_[0];
	$version = $_[1];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_product", $product );
	dumpSingleVarToLog( "$subname" . "_version", $version );

	#Set up maximum supported versions
	my $jiraSupportedVerHigh       = "5.2";
	my $confluenceSupportedVerHigh = "4.3.3";
	my $crowdSupportedVerHigh      = "2.5.2";
	my $fisheyeSupportedVerHigh    = "2.9.0";
	my $bambooSupportedVerHigh     = "4.3.1";
	my $stashSupportedVerHigh      = "1.3.1";

	#Set up supported version for each product
	if ( $product eq "confluence" ) {
		$productVersion = $confluenceSupportedVerHigh;
	}
	elsif ( $product eq "jira" ) {
		$productVersion = $jiraSupportedVerHigh;
	}
	elsif ( $product eq "stash" ) {
		$productVersion = $stashSupportedVerHigh;
	}
	elsif ( $product eq "fisheye" ) {
		$productVersion = $fisheyeSupportedVerHigh;
	}
	elsif ( $product eq "crowd" ) {
		$productVersion = $crowdSupportedVerHigh;
	}
	elsif ( $product eq "bamboo" ) {
		$productVersion = $bambooSupportedVerHigh;
	}
	else {
		print
"That package is not recognised - Really you should never get here so if you managed to *wavesHi*";
		exit 2;
	}

	$versionReturn = compareTwoVersions( $version, $productVersion );

	#If the version is supported return true
	if ( $versionReturn eq "LESS" || $versionReturn eq "EQUAL" ) {
		$log->info(
"$subname: Version provided ($version) of $product is supported (max supported version is $productVersion)."
		);
		return "yes";
	}
	else {
		$log->info(
"$subname: Version provided ($version) of $product is NOT supported (max supported version is $productVersion)."
		);
		return "no";
	}

}

########################################
#backupFile                            #
########################################
sub backupFile {
	my $inputFile;
	my $osUser;
	my $date = strftime "%Y%m%d_%H%M%S", localtime;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	$inputFile = $_[0];
	$osUser    = $_[1];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_inputFile", $inputFile );
	dumpSingleVarToLog( "$subname" . "_osUser",    $osUser );

	#Create copy of input file with date_time appended to the end of filename
	$log->info(
		"$subname: Backing up $inputFile to " . $inputFile . "_" . $date );
	copy( $inputFile, $inputFile . "_" . $date )
	  or $log->logdie( "File copy failed for $inputFile, "
		  . $inputFile . "_"
		  . $date
		  . ": $!" );
	$log->info( "$subname: Input file '$inputFile' copied to "
		  . $inputFile . "_"
		  . $date );

	chownFile( $osUser, $inputFile . "_" . $date );
}

########################################
#copyFile                            #
########################################
sub copyFile {
	my $inputFile;
	my $outputFile;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	$inputFile  = $_[0];
	$outputFile = $_[1];    #can also be a directory

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_inputFile",  $inputFile );
	dumpSingleVarToLog( "$subname" . "_outputFile", $outputFile );

	#Create copy of input file to output file
	$log->info("$subname: Copying $inputFile to $outputFile");
	copy( $inputFile, $outputFile )
	  or $log->logdie("File copy failed for $inputFile to $outputFile: $!");
	$log->info("$subname: Input file '$inputFile' copied to $outputFile");
}

########################################
#GenerateInitD                         #
########################################
sub generateInitD {
	my $application;
	my $lcApplication;
	my $runUser;
	my $baseDir;
	my $startCmd;
	my $stopCmd;
	my @initFile;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	$application = $_[0];
	$runUser     = $_[1];
	$baseDir     = $_[2];
	$startCmd    = $_[3];
	$stopCmd     = $_[4];

	$lcApplication = lc($application);

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_application", $application );
	dumpSingleVarToLog( "$subname" . "_runUser",     $runUser );
	dumpSingleVarToLog( "$subname" . "_baseDir",     $baseDir );
	dumpSingleVarToLog( "$subname" . "_startCmd",    $startCmd );
	dumpSingleVarToLog( "$subname" . "_stopCmd",     $stopCmd );

	#generate INITD file
	@initFile = (
		"#!/bin/sh -e\n",
		"#" . $application . " startup script\n",
		"#chkconfig: 2345 80 05\n",
		"#description: " . $application . "\n",
		"\n",
		"APP=" . $lcApplication . "\n",
		"USER=" . $runUser . "\n",
		"BASE=" . $baseDir . "\n",
		"STARTCOMMAND=\"" . $startCmd . "\"\n",
		"STOPCOMMAND=\"" . $stopCmd . "\"\n",
		"\n",
		'case "$1" in' . "\n",
		"  # Start command\n",
		"  start)\n",
		'    echo "Starting $APP"' . "\n",
		'    /bin/su -m $USER -c "$BASE/$STARTCOMMAND &> /dev/null"' . "\n",
		"    ;;\n",
		"  # Stop command\n",
		"  stop)\n",
		'    echo "Stopping $APP"' . "\n",
		'    /bin/su -m $USER -c "$BASE/$STOPCOMMAND &> /dev/null"' . "\n",
		'    echo "$APP stopped successfully"' . "\n",
		"    ;;\n",
		"   # Restart command\n",
		"   restart)\n",
		'        $0 stop' . "\n",
		"        sleep 5\n",
		'        $0 start' . "\n",
		"        ;;\n",
		"  *)\n",
		'    echo "Usage: /etc/init.d/$APP {start|restart|stop}"' . "\n",
		"    exit 1\n",
		"    ;;\n",
		"esac\n",
		"\n",
		"exit 0\n"
	);

	#Write out file to /etc/init.d
	$log->info("$subname: Writing out init.d file for $application.");
	open FILE, ">/etc/init.d/$lcApplication"
	  or $log->logdie("Unable to open file /etc/init.d/$lcApplication: $!");
	print FILE @initFile;
	close FILE;

	#Make the new init.d file executable
	$log->info("$subname: Chmodding init.d file for $lcApplication.");
	chmod 0755, "/etc/init.d/$lcApplication"
	  or $log->logdie("Couldn't chmod /etc/init.d/$lcApplication: $!");

}

########################################
#LoadSuiteConfig                       #
########################################
sub loadSuiteConfig {

	#Test if config file exists, if so load it
	if ( -e $configFile ) {
		$globalConfig = new Config::Simple($configFile);
	}
}

########################################
#Install Generic Atlassian Binary      #
########################################
sub installGenericAtlassianBinary {
	my $input;
	my $mode;
	my $version;
	my $application;
	my $lcApplication;
	my @downloadDetails;
	my $archiveLocation;
	my $osUser;
	my $VERSIONLOOP = 1;
	my @uidGid;
	my $connectorPortAvailCode;
	my $serverPortAvailCode;
	my $varfile;
	my @requiredConfigItems;
	my $downloadArchivesUrl;
	my $configUser;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	$application         = $_[0];
	$downloadArchivesUrl = $_[1];
	$configUser =
	  $_[2];   #Note this is the param name used in the bin/user.sh file we need
	@requiredConfigItems = @{ $_[3] };

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_application", $application );
	dumpSingleVarToLog( "$subname" . "_downloadArchivesUrl",
		$downloadArchivesUrl );
	dumpSingleVarToLog( "$subname" . "_configUser", $configUser );
	dumpSingleVarToLog( "$subname" . "_requiredConfigItems",
		@requiredConfigItems );

	$lcApplication = lc($application);
	$varfile =
	    $globalConfig->param("general.rootInstallDir") . "/"
	  . $lcApplication
	  . "-install.varfile";
	dumpSingleVarToLog( "$subname" . "_varfile", $varfile );

#Iterate through required config items, if an are missing force an update of configuration
	if ( checkRequiredConfigItems(@requiredConfigItems) eq "FAIL" ) {
		$log->info(
"$subname: Some of the config parameters are invalid or null. Forcing generation"
		);
		print
"Some of the $application config parameters are incomplete. You must review the $application configuration before continuing: \n\n";
		generateApplicationConfig( $application, "UPDATE", $globalConfig );
	}

	#Otherwise provide the option to update the configuration before proceeding
	else {
		print
"Would you like to review the $application config before installing? Yes/No [yes]: ";

		$input = getBooleanInput();
		print "\n";
		if ( $input eq "default" || $input eq "yes" ) {
			$log->info(
				"$subname: User opted to update config prior to installation.");
			generateApplicationConfig( $application, "UPDATE", $globalConfig );
		}
	}

	$serverPortAvailCode =
	  isPortAvailable( $globalConfig->param( $lcApplication . ".serverPort" ) );

	$connectorPortAvailCode = isPortAvailable(
		$globalConfig->param( $lcApplication . ".connectorPort" ) );

	if ( $serverPortAvailCode == 0 || $connectorPortAvailCode == 0 ) {
		$log->info(
"$subname: ServerPortAvailCode=$serverPortAvailCode, ConnectorPortAvailCode=$connectorPortAvailCode. Whichever one equals 0 
is currently in use. Unfortunately with the Atlassian binary installers we cannot proceed as they will fail. 
Therefore script is terminating, please ensure port configuration is correct and no services are actively using the ports."
		);
		$log->logdie(
"One or more of the ports configured for $application are currently in use. Cannot continue installing. "
			  . "Please ensure the ports configured are available and not in use.\n\n"
		);
	}

	print "Would you like to install the latest version? yes/no [yes]: ";

	$input = getBooleanInput();
	print "\n";
	if ( $input eq "default" || $input eq "yes" ) {
		$log->info(
			"$subname: User opted to install latest version of $application");
		$mode = "LATEST";
	}
	else {
		$log->info(
			"$subname: User opted to install specific version of $application");
		$mode = "SPECIFIC";
	}

	#If a specific version is selected, ask for the version number
	if ( $mode eq "SPECIFIC" ) {
		while ( $VERSIONLOOP == 1 ) {
			print
			  "Please enter the version number you would like. i.e. 4.2.2 []: ";

			$version = <STDIN>;
			print "\n";
			chomp $version;
			dumpSingleVarToLog( "$subname" . "_versionEntered", $version );

			#Check that the input version actually exists
			print
"Please wait, checking that version $version of $application exists (may take a few moments)... \n\n";

			#get the version specific URL to test
			@downloadDetails =
			  getVersionDownloadURL( $lcApplication, $globalArch, $version );

			#Try to get the header of the version URL to ensure it exists
			if ( head( $downloadDetails[0] ) ) {
				$VERSIONLOOP = 0;
				$log->info(
"$subname: User selected to install version $version of $application"
				);
				print "$application version $version found. Continuing...\n\n";
			}
			else {
				$log->warn(
"$subname: User selected to install version $version of $application. No such version exists, asking for input again."
				);
				print
"No such version of $application exists. Please visit $downloadArchivesUrl and pick a valid version number and try again.\n\n";
			}
		}

	}

	#Download the latest version
	if ( $mode eq "LATEST" ) {
		$log->info("$subname: Downloading latest version of $application");
		@downloadDetails =
		  downloadAtlassianInstaller( $mode, $lcApplication, "", $globalArch );
		$version = $downloadDetails[1];

	}

	#Download a specific version
	else {
		$log->info("$subname: Downloading version $version of $application");
		@downloadDetails =
		  downloadAtlassianInstaller( $mode, $lcApplication, $version,
			$globalArch );
	}

	#chmod the file to be executable
	$log->info("$subname: Making $downloadDetails[2] excecutable ");
	chmod 0755, $downloadDetails[2]
	  or $log->logdie( "Couldn't chmod " . $downloadDetails[2] . ": $!" );

	#Generate the kickstart as we have all the information necessary
	$log->info(
		"$subname: Generating kickstart file for $application at $varfile");
	generateGenericKickstart( $varfile, "INSTALL", $lcApplication );

	if ( -d $globalConfig->param( $lcApplication . ".installDir" ) ) {
		print "The current installation directory ("
		  . $globalConfig->param( $lcApplication . ".installDir" )
		  . ") exists.\nIf you are sure there is not another version installed here would you like to move it to a backup? [yes]: ";
		$input = getBooleanInput();
		print "\n";
		if ( $input eq "default" || $input eq "yes" ) {
			$log->info(
"$subname: Current install directory for $application exists, user has selected to back this up."
			);
			backupDirectoryAndChown(
				$globalConfig->param( $lcApplication . ".installDir" ),
				"root" )
			  ; #we have to use root here as due to the way Atlassian Binaries do installs there is no way to know if user exists or not.
		}
		else {
			$log->logdie(
"Cannot proceed installing $application if the directory already has an install, please remove this manually and try again.\n\n"
			);
		}
	}

	if ( -d $globalConfig->param( $lcApplication . ".dataDir" ) ) {
		print "The current installation directory ("
		  . $globalConfig->param( $lcApplication . ".dataDir" )
		  . ") exists.\nIf you are sure there is not another version installed here would you like to move it to a backup? [yes]: ";
		$input = getBooleanInput();
		print "\n";
		if ( $input eq "default" || $input eq "yes" ) {
			$log->info(
"$subname: Current data directory for $application exists, user has selected to back this up."
			);
			backupDirectoryAndChown(
				$globalConfig->param( $lcApplication . ".dataDir" ), "root" )
			  ; #we have to use root here as due to the way Atlassian Binaries do installs there is no way to know if user exists or not.
		}
		else {
			$log->logdie(
				"Cannot proceed installing $application if the data directory ("
				  . $globalConfig->param( $lcApplication . ".dataDir" )
				  . ")already has data from a previous install, please remove this manually and try again.\n\n"
			);
		}

	}

	#install
	$log->info(
		"$subname: Running " . $downloadDetails[2] . " -q -varfile $varfile" );
	system( $downloadDetails[2] . " -q -varfile $varfile" );

	if ( $? == -1 ) {
		$log->logdie(
"$application install did not complete successfully. Please check the install logs and try again: $!\n"
		);
	}

	#Stop the application so we can apply additional configuration
	print
"Stopping $application so that we can apply additional config. Sleeping for 60 seconds to ensure $application has completed initial startup. Please wait...\n\n";
	sleep(60);
	$log->info(
"$subname: Stopping $application so that we can apply the additional configuration options."
	);
	system( "service "
		  . $globalConfig->param( $lcApplication . ".osUser" )
		  . " stop" );
	if ( $? == -1 ) {
		$log->warn(
"$subname: Could not stop $application successfully. Please make sure you restart manually following the end of installation"
		);
		warn
"Could not stop $application successfully. Please make sure you restart manually following the end of installation: $!\n\n";
	}

	#Apply the JavaOpts configuration (if any)
	updateJavaOpts(
		$globalConfig->param( $lcApplication . ".installDir" )
		  . "/bin/setenv.sh",
		"JAVA_OPTS",
		$globalConfig->param( $lcApplication . ".javaParams" )
	);

	#getTheUserItWasInstalledAs - Write to config and reload
	$osUser =
	  getUserCreatedByInstaller( $lcApplication . ".installDir", $configUser );
	$log->info("$subname: OS User created by installer is: $osUser");
	$globalConfig->param( $lcApplication . ".osUser", $osUser );
	$log->info("Writing out config file to disk.");
	$globalConfig->write($configFile);
	loadSuiteConfig();

	#Check if user wants to remove the downloaded installer
	print "Do you wish to delete the downloaded installer "
	  . $downloadDetails[2]
	  . "? [yes]: ";
	$input = getBooleanInput();
	print "\n";
	if ( $input eq "default" || $input eq "yes" ) {
		$log->info("$subname: User opted to delete downloaded installer.");
		unlink $downloadDetails[2]
		  or warn "Could not delete " . $downloadDetails[2] . ": $!";
	}

#If MySQL is the Database, Atlassian apps do not come with the driver so copy it

	if ( $globalConfig->param("general.targetDBType") eq "MySQL" ) {
		print
"Database is configured as MySQL, copying the JDBC connector to $application install.\n\n";
		$log->info(
"$subname: Copying MySQL JDBC connector to $application install directory."
		);
		copyFile( $globalConfig->param("general.dbJDBCJar"),
			$globalConfig->param( $lcApplication . ".installDir" ) . "/lib/" );

		#Chown the files again
		$log->info( "$subname: Chowning "
			  . $globalConfig->param( $lcApplication . ".installDir" ) . "/lib/"
			  . " to $osUser following MySQL JDBC install." );
		chownRecursive( $osUser,
			$globalConfig->param( $lcApplication . ".installDir" ) . "/lib/" );

	}

	print "Applying configuration settings to the install, please wait...\n\n";

	print "Creating backup of config files...\n\n";
	$log->info("$subname: Backing up config files.");

	backupFile(
		$globalConfig->param("$lcApplication.installDir") . "/conf/server.xml",
		$osUser
	);

	print "Applying the configured application context...\n\n";
	$log->info( "$subname: Applying application context to "
		  . $globalConfig->param("$lcApplication.installDir")
		  . "/conf/server.xml" );

	#Update the server config with the configured connector port
	updateXMLAttribute(
		$globalConfig->param("$lcApplication.installDir") . "/conf/server.xml",
		"//////Context",
		"path",
		getConfigItem( "$lcApplication.appContext", $globalConfig )
	);

	#Update config to reflect new version that is installed
	$log->info("$subname: Writing new installed version to the config file.");
	$globalConfig->param( $lcApplication . ".installedVersion", $version );
	$log->info("Writing out config file to disk.");
	$globalConfig->write($configFile);
	loadSuiteConfig();
}

########################################
#PostInstallGenericAtlassianBinary     #
########################################
sub postInstallGenericAtlassianBinary {
	my $application;
	my $lcApplication;
	my $input;
	my $subname = ( caller(0) )[3];

	$application   = $_[0];
	$lcApplication = lc($application);

	print "Configuration settings have been applied successfully.\n\n";

	print "Do you wish to start the $application service? yes/no [yes]: ";
	$input = getBooleanInput();
	print "\n";
	if ( $input eq "default" || $input eq "yes" ) {
		$log->info("$subname: User opted to start application service.");
		system( "service "
			  . $globalConfig->param( $lcApplication . ".osUser" )
			  . " start" );
		if ( $? == -1 ) {
			warn
"Could not start $application successfully. Please make sure to do this manually as the service is currently stopped: $!\n\n";
		}
		print "\n\n";
	}
}

########################################
#UpgradeGenericAtlassianBinary         #
########################################
sub upgradeGenericAtlassianBinary {
	my $input;
	my $mode;
	my $version;
	my $application;
	my @downloadDetails;
	my @downloadVersionCheck;
	my $archiveLocation;
	my $osUser;
	my $VERSIONLOOP = 1;
	my @uidGid;
	my @parameterNull;
	my $varfile;
	my @requiredConfigItems;
	my $downloadArchivesUrl;
	my $configUser;
	my $lcApplication;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	$application         = $_[0];
	$downloadArchivesUrl = $_[1];
	$configUser =
	  $_[2];   #Note this is the param name used in the bin/user.sh file we need
	@requiredConfigItems = @{ $_[3] };

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_application", $application );
	dumpSingleVarToLog( "$subname" . "_downloadArchivesUrl",
		$downloadArchivesUrl );
	dumpSingleVarToLog( "$subname" . "_configUser", $configUser );
	dumpSingleVarToLog( "$subname" . "_requiredConfigItems",
		@requiredConfigItems );

	$lcApplication = lc($application);
	$varfile =
	    $globalConfig->param("general.rootInstallDir") . "/"
	  . $lcApplication
	  . "-install.varfile";
	dumpSingleVarToLog( "$subname" . "_varfile", $varfile );

#Iterate through required config items, if an are missing force an update of configuration
	if ( checkRequiredConfigItems(@requiredConfigItems) eq "FAIL" ) {
		$log->info(
"$subname: Some of the config parameters are invalid or null. Forcing generation"
		);
		print
"Some of the $application config parameters are incomplete. You must review the $application configuration before continuing: \n\n";
		generateApplicationConfig( $application, "UPDATE", $globalConfig );
	}

	#Otherwise provide the option to update the configuration before proceeding
	else {
		print
"Would you like to review the $application config before upgrading? Yes/No [yes]: ";

		$input = getBooleanInput();
		print "\n";
		if ( $input eq "default" || $input eq "yes" ) {
			$log->info(
				"$subname: User opted to update config prior to installation.");
			generateApplicationConfig( $application, "UPDATE", $globalConfig );
		}
	}

	#Set up list of config items that are requred for this install to run
	@requiredConfigItems = ("$lcApplication.installedVersion");

#Iterate through required config items, if an are missing force an update of configuration
	if ( checkRequiredConfigItems(@requiredConfigItems) eq "FAIL" ) {
		$log->warn(
"There is no current version of JIRA listed in the config file. Asking for input of current installed version."
		);
		genConfigItem(
			$mode,
			$globalConfig,
			"$lcApplication.installedVersion",
"There is no version listed in the config file for the currently installed version of $application . Please enter the version of $application that is CURRENTLY installed.",
			""
		);
		$log->info("Writing out config file to disk.");
		$globalConfig->write($configFile);
		loadSuiteConfig();
	}

	#We are upgrading, get the latest version
	print "Would you like to upgrade to the latest version? yes/no [yes]: ";

	$input = getBooleanInput();
	print "\n";
	if ( $input eq "default" || $input eq "yes" ) {
		$log->info(
			"$subname: User opted to install latest version of $application");
		$mode = "LATEST";
	}
	else {
		$log->info(
			"$subname: User opted to install specific version of $application");
		$mode = "SPECIFIC";
	}

	#If a specific version is selected, ask for the version number
	if ( $mode eq "SPECIFIC" ) {
		while ( $VERSIONLOOP == 1 ) {
			print
			  "Please enter the version number you would like. i.e. 4.2.2 []: ";

			$version = <STDIN>;
			print "\n";
			chomp $version;
			dumpSingleVarToLog( "$subname" . "_versionEntered", $version );

			#Check that the input version actually exists
			print
"Please wait, checking that version $version of $application exists (may take a few moments)... \n\n";

			#get the version specific URL to test
			@downloadDetails =
			  getVersionDownloadURL( $lcApplication, $globalArch, $version );

			#Try to get the header of the version URL to ensure it exists
			if ( head( $downloadDetails[0] ) ) {
				$log->info(
"$subname: User selected to install version $version of $application"
				);
				$VERSIONLOOP = 0;
				print "$application version $version found. Continuing...\n\n";
			}
			else {
				$log->warn(
"$subname: User selected to install version $version of $application. No such version exists, asking for input again."
				);
				print
"No such version of $application exists. Please visit $downloadArchivesUrl and pick a valid version number and try again.\n\n";
			}
		}

	}

	#Get the URL for the version we want to download
	if ( $mode eq "LATEST" ) {
		$log->info("$subname: Downloading latest version of $application");
		@downloadVersionCheck =
		  getLatestDownloadURL( $lcApplication, $globalArch );
		my $versionSupported = compareTwoVersions(
			$globalConfig->param("$lcApplication.installedVersion"),
			$downloadVersionCheck[1] );
		if ( $versionSupported eq "GREATER" ) {
			$log->logdie( "The version to be downloaded ("
				  . $downloadVersionCheck[1]
				  . ") is older than the currently installed version ("
				  . $globalConfig->param("$lcApplication.installedVersion")
				  . "). Downgrading is not supported and this script will now exit.\n\n"
			);
		}
	}
	elsif ( $mode eq "SPECIFIC" ) {
		$log->info("$subname: Downloading version $version of $application");
		my $versionSupported = compareTwoVersions(
			$globalConfig->param("$lcApplication.installedVersion"), $version );
		if ( $versionSupported eq "GREATER" ) {
			$log->logdie( "The version to be downloaded (" 
				  . $version
				  . ") is older than the currently installed version ("
				  . $globalConfig->param("$lcApplication.installedVersion")
				  . "). Downgrading is not supported and this script will now exit.\n\n"
			);
		}
	}

	#Download the latest version
	if ( $mode eq "LATEST" ) {
		@downloadDetails =
		  downloadAtlassianInstaller( $mode, $lcApplication, "", $globalArch );
		$version = $downloadDetails[1];

	}

	#Download a specific version
	else {
		@downloadDetails =
		  downloadAtlassianInstaller( $mode, $lcApplication, $version,
			$globalArch );
	}

	#chmod the file to be executable
	$log->info("$subname: Making $downloadDetails[2] excecutable ");
	chmod 0755, $downloadDetails[2]
	  or $log->logdie( "Couldn't chmod " . $downloadDetails[2] . ": $!" );

	#Generate the kickstart as we have all the information necessary
	$log->info(
		"$subname: Generating kickstart file for $application at $varfile");
	generateGenericKickstart( $varfile, "UPGRADE", $lcApplication );

	#upgrade
	$log->info(
		"$subname: Running " . $downloadDetails[2] . " -q -varfile $varfile" );
	system( $downloadDetails[2] . " -q -varfile $varfile" );
	if ( $? == -1 ) {
		$log->logdie(
"$application upgrade did not complete successfully. Please check the install logs and try again: $!\n"
		);
	}

	#Stop the application so we can apply additional configuration
	$log->info(
"$subname: Stopping $application so that we can apply the additional configuration options."
	);
	print
"Stopping $application so that we can apply additional config. Sleeping for 60 seconds to ensure $application has completed initial startup. Please wait...\n\n";
	sleep(60);
	system( "service "
		  . $globalConfig->param( $lcApplication . ".osUser" )
		  . " stop" );
	if ( $? == -1 ) {
		$log->warn(
"$subname: Could not stop $application successfully. Please make sure you restart manually following the end of installation"
		);
		warn
"Could not stop $application successfully. Please make sure you restart manually following the end of installation: $!\n\n";
	}

	#Update config to reflect new version that is installed
	$log->info("$subname: Writing new installed version to the config file.");
	$globalConfig->param( "$lcApplication.installedVersion", $version );
	$log->info("Writing out config file to disk.");
	$globalConfig->write($configFile);
	loadSuiteConfig();

	#getTheUserItWasInstalledAs - Write to config and reload
	$osUser =
	  getUserCreatedByInstaller( "$lcApplication.installDir", $configUser );
	$globalConfig->param( "$lcApplication.osUser", $osUser );
	$log->info("$subname: OS User created by installer is: $osUser");
	$log->info("Writing out config file to disk.");
	$globalConfig->write($configFile);
	loadSuiteConfig();

	#Check if user wants to remove the downloaded installer
	print "Do you wish to delete the downloaded installer "
	  . $downloadDetails[2]
	  . "? [yes]: ";
	$input = getBooleanInput();
	print "\n";
	if ( $input eq "default" || $input eq "yes" ) {
		$log->info("$subname: User opted to delete downloaded installer.");
		unlink $downloadDetails[2]
		  or warn "Could not delete " . $downloadDetails[2] . ": $!";
	}

	#Apply the JavaOpts configuration (if any)
	updateJavaOpts(
		$globalConfig->param( $lcApplication . ".installDir" )
		  . "/bin/setenv.sh",
		"JAVA_OPTS",
		$globalConfig->param( $lcApplication . ".javaParams" )
	);

#If MySQL is the Database, Atlassian apps do not come with the driver so copy it

	if ( $globalConfig->param("general.targetDBType") eq "MySQL" ) {
		print
"Database is configured as MySQL, copying the JDBC connector to $application install.\n\n";
		$log->info(
"$subname: Copying MySQL JDBC connector to $application install directory."
		);
		copyFile( $globalConfig->param("general.dbJDBCJar"),
			$globalConfig->param( $lcApplication . ".installDir" ) . "/lib/" );

		#Chown the files again
		$log->info( "$subname: Chowning "
			  . $globalConfig->param( $lcApplication . ".installDir" )
			  . "/lib/" );
		chownRecursive( $osUser,
			$globalConfig->param("$lcApplication.installDir") . "/lib/" );
	}

	print "Applying configuration settings to the install, please wait...\n\n";

	print "Creating backup of config files...\n\n";
	$log->info("$subname: Backing up config files.");

	backupFile(
		$globalConfig->param("$lcApplication.installDir") . "/conf/server.xml",
		$osUser
	);

	print "Applying the configured application context...\n\n";
	$log->info( "$subname: Applying application context to "
		  . $globalConfig->param("$lcApplication.installDir")
		  . "/conf/server.xml" );

	#Update the server config with the configured connector port
	updateXMLAttribute(
		$globalConfig->param("$lcApplication.installDir") . "/conf/server.xml",
		"//////Context",
		"path",
		getConfigItem( "$lcApplication.appContext", $globalConfig )
	);

}

########################################
#UninstallGenericAtlassianBinary       #
########################################
sub uninstallGenericAtlassianBinary {
	my $application;
	my $lcApplication;
	my $input;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	$application = $_[0];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_application", $application );

	$lcApplication = lc($application);

	print
"This will uninstall $application using the Atlassian provided uninstall script.\n";
	print
"You have been warned, proceed only if you have backed up your installation as there is no turning back.\n\n";
	print "Do you really want to continue? yes/no [no]: ";

	$input = getBooleanInput();
	print "\n";
	if ( $input eq "yes" ) {

		system( $globalConfig->param("$lcApplication.installDir")
			  . "/uninstall -q" );
		if ( $? == -1 ) {
			$log->logdie(
"$application uninstall did not complete successfully. Please check the logs and complete manually: $!\n"
			);
		}

		#Check if you REALLY want to remove data directory
		print
"We will now remove the data directory ($application home directory). Are you REALLY REALLY REALLY (REALLY) sure you want to do this? (not recommended) yes/no [no]: \n";
		$input = getBooleanInput();
		print "\n";
		if ( $input eq "yes" ) {
			rmtree( [ $globalConfig->param("$lcApplication.dataDir") ] );
		}
		else {
			print
"The data directory has not been deleted and is still available at "
			  . $globalConfig->param("$lcApplication.dataDir") . ".\n\n";
		}

		#Update config to reflect that no version is installed
		$globalConfig->param( "$lcApplication.installedVersion", "" );
		$globalConfig->param( "$lcApplication.enable",           "FALSE" );
		$log->info("Writing out config file to disk.");
		$globalConfig->write($configFile);
		loadSuiteConfig();

		print
"$application has been uninstalled successfully and the config file updated to reflect $application as disabled. Press enter to continue...\n\n";
		$input = <STDIN>;
	}
}

########################################
#Install Confluence                    #
########################################
sub installConfluence {
	my $application   = "Confluence";
	my $lcApplication = lc($application);
	my $javaMemParameterFile;
	my $osUser;
	my $downloadArchivesUrl =
	  "http://www.atlassian.com/software/confluence/download-archives";
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	#Set up list of config items that are requred for this install to run
	my @requiredConfigItems;
	@requiredConfigItems = (
		"confluence.appContext",    "confluence.enable",
		"confluence.dataDir",       "confluence.installDir",
		"confluence.runAsService",  "confluence.serverPort",
		"confluence.connectorPort", "confluence.javaMinMemory",
		"confluence.javaMaxMemory", "confluence.javaMaxPermSize"
	);

	#Run generic installer steps
	installGenericAtlassianBinary(
		$application, $downloadArchivesUrl,
		"CONF_USER",  \@requiredConfigItems
	);

	$osUser = $globalConfig->param("$lcApplication.osUser");

	$javaMemParameterFile =
	  $globalConfig->param("$lcApplication.installDir") . "/bin/setenv.sh";
	backupFile( $javaMemParameterFile, $osUser );

	#Run any additional steps

	#Update Java Memory Parameters
	print "Applying Java memory configuration to install...\n\n";
	$log->info( "$subname: Applying Java memory parameters to "
		  . $javaMemParameterFile );
	updateJavaMemParameter( $javaMemParameterFile, "JAVA_OPTS", "-Xms",
		$globalConfig->param("$lcApplication.javaMinMemory") );
	updateJavaMemParameter( $javaMemParameterFile, "JAVA_OPTS", "-Xmx",
		$globalConfig->param("$lcApplication.javaMaxMemory") );
	updateJavaMemParameter( $javaMemParameterFile, "JAVA_OPTS",
		"-XX:MaxPermSize=",
		$globalConfig->param("$lcApplication.javaMaxPermSize") );

	postInstallGenericAtlassianBinary($application);

}

########################################
#UpgradeConfluence                     #
########################################
sub upgradeConfluence {
	my $application   = "Confluence";
	my $lcApplication = lc($application);
	my $javaMemParameterFile;
	my $osUser;
	my $downloadArchivesUrl =
	  "http://www.atlassian.com/software/confluence/download-archives";
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	#Set up list of config items that are requred for this install to run
	my @requiredConfigItems;
	@requiredConfigItems = (
		"confluence.appContext",    "confluence.enable",
		"confluence.dataDir",       "confluence.installDir",
		"confluence.runAsService",  "confluence.serverPort",
		"confluence.connectorPort", "confluence.javaMinMemory",
		"confluence.javaMaxMemory", "confluence.javaMaxPermSize"
	);

	upgradeGenericAtlassianBinary(
		$application, $downloadArchivesUrl,
		"CONF_USER",  \@requiredConfigItems
	);

	$osUser = $globalConfig->param("$lcApplication.osUser");

	$javaMemParameterFile =
	  $globalConfig->param("$lcApplication.installDir") . "/bin/setenv.sh";
	backupFile( $javaMemParameterFile, $osUser );

	#Run any additional steps

	#Update Java Memory Parameters
	print "Applying Java memory configuration to install...\n\n";
	$log->info( "$subname: Applying Java memory parameters to "
		  . $javaMemParameterFile );
	updateJavaMemParameter( $javaMemParameterFile, "JAVA_OPTS", "-Xms",
		$globalConfig->param("$lcApplication.javaMinMemory") );
	updateJavaMemParameter( $javaMemParameterFile, "JAVA_OPTS", "-Xmx",
		$globalConfig->param("$lcApplication.javaMaxMemory") );
	updateJavaMemParameter( $javaMemParameterFile, "JAVA_OPTS",
		"-XX:MaxPermSize=",
		$globalConfig->param("$lcApplication.javaMaxPermSize") );

	postInstallGenericAtlassianBinary($application);
}

########################################
#Uninstall Confluence                  #
########################################
sub uninstallConfluence {
	my $application = "Confluence";
	my $subname     = ( caller(0) )[3];

	$log->info("BEGIN: $subname");
	uninstallGenericAtlassianBinary($application);
}

########################################
#Install Jira                          #
########################################
sub installJira {
	my $application   = "JIRA";
	my $lcApplication = lc($application);
	my $javaMemParameterFile;
	my $osUser;
	my $downloadArchivesUrl =
	  "http://www.atlassian.com/software/jira/download-archives";
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	#Set up list of config items that are requred for this install to run
	my @requiredConfigItems;
	@requiredConfigItems = (
		"jira.appContext",    "jira.enable",
		"jira.dataDir",       "jira.installDir",
		"jira.runAsService",  "jira.serverPort",
		"jira.connectorPort", "jira.javaMinMemory",
		"jira.javaMaxMemory", "jira.javaMaxPermSize"
	);

	#Run generic installer steps
	installGenericAtlassianBinary(
		$application, $downloadArchivesUrl,
		"JIRA_USER",  \@requiredConfigItems
	);

	$osUser = $globalConfig->param("$lcApplication.osUser");

	$javaMemParameterFile =
	  $globalConfig->param("$lcApplication.installDir") . "/bin/setenv.sh";

#backupFile( $javaOptsFile, $osUser ); # This will already have been backed up as part of install for Jira

	#Run any additional steps

	#Update Java Memory Parameters
	print "Applying Java memory configuration to install...\n\n";
	$log->info( "$subname: Applying Java memory parameters to "
		  . $javaMemParameterFile );
	updateLineInFile(
		$javaMemParameterFile,
		"JVM_MINIMUM_MEMORY",
		"JVM_MINIMUM_MEMORY="
		  . $globalConfig->param("$lcApplication.javaMinMemory"),
		"#JVM_MINIMUM_MEMORY="
	);

	updateLineInFile(
		$javaMemParameterFile,
		"JVM_MAXIMUM_MEMORY",
		"JVM_MAXIMUM_MEMORY="
		  . $globalConfig->param("$lcApplication.javaMaxMemory"),
		"#JVM_MAXIMUM_MEMORY="
	);

	updateLineInFile(
		$javaMemParameterFile,
		"JIRA_MAX_PERM_SIZE",
		"JIRA_MAX_PERM_SIZE="
		  . $globalConfig->param("$lcApplication.javaMaxPermSize"),
		"#JIRA_MAX_PERM_SIZE="
	);

	postInstallGenericAtlassianBinary($application);
}

########################################
#UpgradeJira                          #
########################################
sub upgradeJira {
	my $application   = "JIRA";
	my $lcApplication = lc($application);
	my $javaMemParameterFile;
	my $osUser;
	my $downloadArchivesUrl =
	  "http://www.atlassian.com/software/jira/download-archives";
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	#Set up list of config items that are requred for this install to run
	my @requiredConfigItems;
	@requiredConfigItems = (
		"jira.appContext",    "jira.enable",
		"jira.dataDir",       "jira.installDir",
		"jira.runAsService",  "jira.serverPort",
		"jira.connectorPort", "jira.javaMinMemory",
		"jira.javaMaxMemory", "jira.javaMaxPermSize"
	);

	upgradeGenericAtlassianBinary(
		$application, $downloadArchivesUrl,
		"JIRA_USER",  \@requiredConfigItems
	);

	$osUser = $globalConfig->param("$lcApplication.osUser");

	$javaMemParameterFile =
	  $globalConfig->param("$lcApplication.installDir") . "/bin/setenv.sh";

#backupFile( $javaOptsFile, $osUser ); # This will already have been backed up as part of install for Jira

	#Run any additional steps

	#Update Java Memory Parameters
	print "Applying Java memory configuration to install...\n\n";
	$log->info( "$subname: Applying Java memory parameters to "
		  . $javaMemParameterFile );
	updateLineInFile(
		$javaMemParameterFile,
		"JVM_MINIMUM_MEMORY",
		"JVM_MINIMUM_MEMORY="
		  . $globalConfig->param("$lcApplication.javaMinMemory"),
		"#JVM_MINIMUM_MEMORY="
	);

	updateLineInFile(
		$javaMemParameterFile,
		"JVM_MAXIMUM_MEMORY",
		"JVM_MAXIMUM_MEMORY="
		  . $globalConfig->param("$lcApplication.javaMaxMemory"),
		"#JVM_MAXIMUM_MEMORY="
	);

	updateLineInFile(
		$javaMemParameterFile,
		"JIRA_MAX_PERM_SIZE",
		"JIRA_MAX_PERM_SIZE="
		  . $globalConfig->param("$lcApplication.javaMaxPermSize"),
		"#JIRA_MAX_PERM_SIZE="
	);

	postInstallGenericAtlassianBinary($application);
}

########################################
#Uninstall Jira                        #
########################################
sub uninstallJira {
	my $application = "JIRA";
	my $subname     = ( caller(0) )[3];

	$log->info("BEGIN: $subname");
	uninstallGenericAtlassianBinary($application);
}

########################################
#Install Crowd                         #
########################################
sub installCrowd {
	my $application = "Crowd";
	my $osUser;
	my $lcApplication;
	my $downloadArchivesUrl =
	  "http://www.atlassian.com/software/crowd/download-archive";
	my $serverXMLFile;
	my $initPropertiesFile;
	my $javaMemParameterFile;
	my @requiredConfigItems;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	#Set up list of config items that are requred for this install to run
	$lcApplication       = lc($application);
	@requiredConfigItems = (
		"crowd.appContext",    "crowd.enable",
		"crowd.dataDir",       "crowd.installDir",
		"crowd.runAsService",  "crowd.serverPort",
		"crowd.connectorPort", "crowd.osUser",
		"crowd.tomcatDir",     "crowd.webappDir",
		"crowd.javaMinMemory", "crowd.javaMaxMemory",
		"crowd.javaMaxPermSize"
	);

	#Run generic installer steps
	installGeneric( $application, $downloadArchivesUrl, \@requiredConfigItems );
	$osUser = $globalConfig->param("$lcApplication.osUser")
	  ; #we get this after install in CASE the installer changes the configured user in future

	#Perform application specific configuration
	print "Applying configuration settings to the install, please wait...\n\n";

	$serverXMLFile =
	    $globalConfig->param("$lcApplication.installDir")
	  . $globalConfig->param("$lcApplication.tomcatDir")
	  . "/conf/server.xml";
	$initPropertiesFile =
	    $globalConfig->param("$lcApplication.installDir")
	  . $globalConfig->param("$lcApplication.webappDir")
	  . "/WEB-INF/classes/$lcApplication-init.properties";
	$javaMemParameterFile =
	    $globalConfig->param("$lcApplication.installDir")
	  . $globalConfig->param("$lcApplication.tomcatDir")
	  . "/bin/setenv.sh";

	print "Creating backup of config files...\n\n";
	$log->info("$subname: Backing up config files.");

	backupFile( $serverXMLFile, $osUser );

	backupFile( $initPropertiesFile, $osUser );

	backupFile( $javaMemParameterFile, $osUser );

	print "Applying port numbers to server config...\n\n";

	#Update the server config with the configured connector port
	$log->info( "$subname: Updating the connector port in " . $serverXMLFile );
	updateXMLAttribute( $serverXMLFile, "///Connector", "port",
		$globalConfig->param("$lcApplication.connectorPort") );

	#Update the server config with the configured server port
	$log->info( "$subname: Updating the server port in " . $serverXMLFile );
	updateXMLAttribute( $serverXMLFile, "/Server", "port",
		$globalConfig->param("$lcApplication.serverPort") );

	#Apply application context
	$log->info( "$subname: Applying application context to " . $serverXMLFile );
	print "Applying application context to config...\n\n";
	updateXMLAttribute( $serverXMLFile, "//////Context", "path",
		getConfigItem( "$lcApplication.appContext", $globalConfig ) );

	print "Applying home directory location to config...\n\n";

	#Edit Crowd config file to reference homedir
	$log->info( "$subname: Applying homedir in " . $initPropertiesFile );
	print "Applying home directory to config...\n\n";
	updateLineInFile(
		$initPropertiesFile,
		"crowd.home",
		"$lcApplication.home=" . $globalConfig->param("$lcApplication.dataDir"),
		"#crowd.home=/var/crowd-home"
	);

	#Apply the JavaOpts configuration (if any)
	print "Applying Java_Opts configuration to install...\n\n";
	updateJavaOpts(
		$globalConfig->param( $lcApplication . ".installDir" )
		  . $globalConfig->param( $lcApplication . ".tomcatDir" )
		  . "/bin/setenv.sh",
		"JAVA_OPTS",
		$globalConfig->param( $lcApplication . ".javaParams" )
	);

	#Update Java Memory Parameters
	print "Applying Java memory configuration to install...\n\n";
	$log->info( "$subname: Applying Java memory parameters to "
		  . $javaMemParameterFile );
	updateJavaMemParameter( $javaMemParameterFile, "JAVA_OPTS", "-Xms",
		$globalConfig->param("$lcApplication.javaMinMemory") );
	updateJavaMemParameter( $javaMemParameterFile, "JAVA_OPTS", "-Xmx",
		$globalConfig->param("$lcApplication.javaMaxMemory") );
	updateJavaMemParameter( $javaMemParameterFile, "JAVA_OPTS",
		"-XX:MaxPermSize=",
		$globalConfig->param("$lcApplication.javaMaxPermSize") );

	print "Configuration settings have been applied successfully.\n\n";

	#Run any additional steps

	#Generate the init.d file
	print
"Setting up initd files and run as a service (if configured) please wait...\n\n";
	$log->info("$subname: Generating init.d file for $application.");

	generateInitD( $lcApplication, $osUser,
		$globalConfig->param("$lcApplication.installDir"),
		"start_crowd.sh", "stop_crowd.sh" );

	#Finally run generic post install tasks
	postInstallGeneric($application);
}

########################################
#Install Stash                         #
########################################
sub installStash {
	my $application = "Stash";
	my $osUser;
	my $lcApplication;
	my $downloadArchivesUrl =
	  "http://www.atlassian.com/it/software/stash/download-archives";
	my $serverXMLFile;
	my $initPropertiesFile;
	my $javaMemParameterFile;
	my @requiredConfigItems;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	#Set up list of config items that are requred for this install to run
	$lcApplication       = lc($application);
	@requiredConfigItems = (
		"stash.appContext",    "stash.enable",
		"stash.dataDir",       "stash.installDir",
		"stash.runAsService",  "stash.serverPort",
		"stash.connectorPort", "stash.osUser",
		"stash.tomcatDir",     "stash.webappDir",
		"stash.javaMinMemory", "stash.javaMaxMemory",
		"stash.javaMaxPermSize"
	);

	#Run generic installer steps
	installGeneric( $application, $downloadArchivesUrl, \@requiredConfigItems );
	$osUser = $globalConfig->param("$lcApplication.osUser")
	  ; #we get this after install in CASE the installer changes the configured user in future

	#Perform application specific configuration
	print "Applying configuration settings to the install, please wait...\n\n";

	$serverXMLFile =
	    $globalConfig->param("$lcApplication.installDir")
	  . $globalConfig->param("$lcApplication.tomcatDir")
	  . "/conf/server.xml";

	$initPropertiesFile =
	  $globalConfig->param("$lcApplication.installDir") . "/bin/setenv.sh";

	print "Creating backup of config files...\n\n";
	$log->info("$subname: Backing up config files.");

	backupFile( $serverXMLFile, $osUser );

	backupFile( $initPropertiesFile, $osUser );

	print "Applying port numbers to server config...\n\n";

	#Update the server config with the configured connector port
	$log->info( "$subname: Updating the connector port in " . $serverXMLFile );
	updateXMLAttribute( $serverXMLFile, "///Connector", "port",
		$globalConfig->param("$lcApplication.connectorPort") );

	#Update the server config with the configured server port
	$log->info( "$subname: Updating the server port in " . $serverXMLFile );
	updateXMLAttribute( $serverXMLFile, "/Server", "port",
		$globalConfig->param("$lcApplication.serverPort") );

	#Apply application context
	$log->info( "$subname: Applying application context to " . $serverXMLFile );
	print "Applying application context to config...\n\n";
	updateXMLAttribute( $serverXMLFile, "//////Context", "path",
		getConfigItem( "$lcApplication.appContext", $globalConfig ) );

	print "Applying home directory location to config...\n\n";

	#Edit Stash config file to reference homedir
	$log->info( "$subname: Applying homedir in " . $initPropertiesFile );
	print "Applying home directory to config...\n\n";
	updateLineInFile(
		$initPropertiesFile,
		"STASH_HOME",
		"STASH_HOME=\"" . $globalConfig->param("$lcApplication.dataDir") . "\"",
		"#STASH_HOME="
	);

	#Apply the JavaOpts configuration (if any)
	print "Applying Java_Opts configuration to install...\n\n";
	updateJavaOpts(
		$globalConfig->param( $lcApplication . ".installDir" )
		  . "/bin/setenv.sh",
		"JVM_REQUIRED_ARGS",
		$globalConfig->param( $lcApplication . ".javaParams" )
	);

	print "Configuration settings have been applied successfully.\n\n";

	#Run any additional steps

	#Update Java Memory Parameters
	print "Applying Java memory configuration to install...\n\n";
	$log->info( "$subname: Applying Java memory parameters to "
		  . $javaMemParameterFile );
	updateLineInFile(
		$javaMemParameterFile,
		"JVM_MINIMUM_MEMORY",
		"JVM_MINIMUM_MEMORY="
		  . $globalConfig->param("$lcApplication.javaMinMemory"),
		"#JVM_MINIMUM_MEMORY="
	);

	updateLineInFile(
		$javaMemParameterFile,
		"JVM_MAXIMUM_MEMORY",
		"JVM_MAXIMUM_MEMORY="
		  . $globalConfig->param("$lcApplication.javaMaxMemory"),
		"#JVM_MAXIMUM_MEMORY="
	);

	updateLineInFile(
		$javaMemParameterFile,
		"STASH_MAX_PERM_SIZE",
		"STASH_MAX_PERM_SIZE="
		  . $globalConfig->param("$lcApplication.javaMaxPermSize"),
		"#STASH_MAX_PERM_SIZE="
	);

	#Generate the init.d file
	print
"Setting up initd files and run as a service (if configured) please wait...\n\n";
	$log->info("$subname: Generating init.d file for $application.");

	generateInitD( $lcApplication, $osUser,
		$globalConfig->param("$lcApplication.installDir"),
		"/bin/start-stash.sh", "/bin/stop-stash.sh" );

	#Finally run generic post install tasks
	postInstallGeneric($application);
}

########################################
#Install Fisheye                       #
########################################
sub installFisheye {
	my $input;
	my $application = "Fisheye";
	my $osUser;
	my $serverXMLFile;
	my $javaMemParameterFile;
	my $lcApplication;
	my $downloadArchivesUrl =
	  "http://www.atlassian.com/software/fisheye/download-archives";
	my $configFile;
	my @requiredConfigItems;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	#Set up list of config items that are requred for this install to run
	$lcApplication       = lc($application);
	@requiredConfigItems = (
		"fisheye.appContext",    "fisheye.enable",
		"fisheye.dataDir",       "fisheye.installDir",
		"fisheye.runAsService",  "fisheye.osUser",
		"fisheye.serverPort",    "fisheye.connectorPort",
		"fisheye.tomcatDir",     "fisheye.webappDir",
		"fisheye.javaMinMemory", "fisheye.javaMaxMemory",
		"fisheye.javaMaxPermSize"
	);

	#Run generic installer steps
	installGeneric( $application, $downloadArchivesUrl, \@requiredConfigItems );
	$osUser = $globalConfig->param("$lcApplication.osUser")
	  ; #we get this after install in CASE the installer changes the configured user in future

	#Perform application specific configuration
	print "Copying example config file, please wait...\n\n";
	$serverXMLFile =
	  $globalConfig->param("$lcApplication.dataDir") . "/config.xml";
	copyFile( $globalConfig->param("$lcApplication.installDir") . "/config.xml",
		$serverXMLFile );
	chownFile( $osUser, $serverXMLFile );

	print "Applying configuration settings to the install, please wait...\n\n";

	print "Creating backup of config files...\n\n";
	$log->info("$subname: Backing up config files.");

	backupFile( $serverXMLFile, $osUser );

	print "Applying port numbers to server config...\n\n";

	#Update the server config with the configured connector port
	$log->info( "$subname: Updating the connector port in " . $serverXMLFile );
	updateXMLAttribute( $serverXMLFile, "//http", "bind",
		":" . $globalConfig->param("$lcApplication.connectorPort") );

	#Update the server config with the configured server port
	$log->info( "$subname: Updating the server port in " . $serverXMLFile );
	updateXMLAttribute( $serverXMLFile, "/config", "control-bind",
		"127.0.0.1:" . $globalConfig->param("$lcApplication.serverPort") );

	#Apply application context
	$log->info( "$subname: Applying application context to " . $serverXMLFile );
	print "Applying application context to config...\n\n";
	updateXMLAttribute( $serverXMLFile, "web-server", "context",
		getConfigItem( "$lcApplication.appContext", $globalConfig ) );

	$javaMemParameterFile =
	  $globalConfig->param("$lcApplication.installDir") . "/bin/fisheyectl.sh";

	print "Applying Java memory configuration to install...\n\n";
	$log->info( "$subname: Applying Java memory parameters to "
		  . $javaMemParameterFile );
	updateJavaMemParameter( $javaMemParameterFile, "FISHEYE_OPTS", "-Xms",
		$globalConfig->param("$lcApplication.javaMinMemory") );

	updateJavaMemParameter( $javaMemParameterFile, "FISHEYE_OPTS", "-Xmx",
		$globalConfig->param("$lcApplication.javaMaxMemory") );

	updateJavaMemParameter( $javaMemParameterFile, "FISHEYE_OPTS",
		"-XX:MaxPermSize=",
		$globalConfig->param("$lcApplication.javaMaxPermSize") );

	#Apply the JavaOpts configuration (if any)
	print "Applying Java_Opts configuration to install...\n\n";
	updateJavaOpts(
		$globalConfig->param( $lcApplication . ".installDir" )
		  . "/bin/fisheyectl.sh",
		"FISHEYE_OPTS",
		$globalConfig->param( $lcApplication . ".javaParams" )
	);

	print "Configuration settings have been applied successfully.\n\n";

	#Run any additional steps
	my $environmentProfileFile = "/etc/environment";
	$log->info(
"$subname: Inserting the FISHEYE_INST variable into '$environmentProfileFile'"
		  . $serverXMLFile );
	print
	  "Inserting the FISHEYE_INST variable into '$environmentProfileFile'.\n\n";
	updateEnvironmentVars( $environmentProfileFile, "FISHEYE_INST",
		$globalConfig->param("$lcApplication.dataDir") );

	#Generate the init.d file
	print
"Setting up initd files and run as a service (if configured) please wait...\n\n";
	$log->info("$subname: Generating init.d file for $application.");

	generateInitD( $lcApplication, $osUser,
		$globalConfig->param("$lcApplication.installDir") . "/bin/",
		"start.sh", "stop.sh" );

#Finally run generic post install tasks
#postInstallGeneric($application);
#For the time being we do not run using post installer generic as a reboot is required before service can start
#If set to run as a service, set to run on startup
	if ( $globalConfig->param("$lcApplication.runAsService") eq "TRUE" ) {
		$log->info(
			"$subname: Setting up $application as a service to run on startup."
		);
		manageService( "INSTALL", $lcApplication );
	}
	print "Services configured successfully.\n\n";

	#Check if we should start the service
	print
"Installation has completed successfully. The service SHOULD NOT be started before rebooting the server to reload /etc/environment.\n"
	  . "Please remember to reboot the server before attempting to start Fisheye. Press enter to continue.";
	$input = <STDIN>;

}

########################################
#Install Bamboo                        #
########################################
sub installBamboo {
	my $input;
	my $application = "Bamboo";
	my $osUser;
	my $serverConfigFile;
	my $javaMemParameterFile;
	my $lcApplication;
	my $downloadArchivesUrl =
	  "http://www.atlassian.com/software/bamboo/download-archives";
	my $configFile;
	my @requiredConfigItems;
	my $WrapperDownloadFile;
	my $WrapperDownloadUrlFor64Bit =
"https://confluence.atlassian.com/download/attachments/289276785/Bamboo_64_Bit_Wrapper.zip?version=1&modificationDate=1346435557878&api=v2";
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	#Set up list of config items that are requred for this install to run
	$lcApplication       = lc($application);
	@requiredConfigItems = (
		"bamboo.appContext",    "bamboo.enable",
		"bamboo.dataDir",       "bamboo.installDir",
		"bamboo.runAsService",  "bamboo.osUser",
		"bamboo.connectorPort", "bamboo.javaMinMemory",
		"bamboo.javaMaxMemory", "bamboo.javaMaxPermSize"
	);

	#Run generic installer steps
	installGeneric( $application, $downloadArchivesUrl, \@requiredConfigItems );
	$osUser = $globalConfig->param("$lcApplication.osUser")
	  ; #we get this after install in CASE the installer changes the configured user in future

	#Perform application specific configuration
	print "Applying configuration settings to the install, please wait...\n\n";

	$serverConfigFile =
	  $globalConfig->param("$lcApplication.installDir") . "/conf/wrapper.conf";

	print "Creating backup of config files...\n\n";
	$log->info("$subname: Backing up config files.");

	backupFile( $serverConfigFile, $osUser );

	print "Applying port numbers to server config...\n\n";

	updateLineInFile(
		$serverConfigFile,
		"wrapper.app.parameter.2",
		"wrapper.app.parameter.2="
		  . $globalConfig->param("$lcApplication.connectorPort"),
		""
	);

	#Apply application context
	updateLineInFile(
		$serverConfigFile,
		"wrapper.app.parameter.4",
		"wrapper.app.parameter.4="
		  . $globalConfig->param("$lcApplication.appContext"),
		""
	);

	print "Applying Java memory configuration to install...\n\n";
	$log->info( "$subname: Applying Java memory parameters to "
		  . $javaMemParameterFile );
	$javaMemParameterFile =
	  $globalConfig->param("$lcApplication.installDir") . "/conf/wrapper.conf";
	backupFile( $javaMemParameterFile, $osUser );

	updateLineInBambooWrapperConf( $javaMemParameterFile,
		"wrapper.java.additional.", "-Xms",
		$globalConfig->param("$lcApplication.javaMinMemory") );

	updateLineInBambooWrapperConf( $javaMemParameterFile,
		"wrapper.java.additional.", "-Xmx",
		$globalConfig->param("$lcApplication.javaMaxMemory") );

	updateLineInBambooWrapperConf( $javaMemParameterFile,
		"wrapper.java.additional.", "-XX:MaxPermSize=",
		$globalConfig->param("$lcApplication.javaMaxPermSize") );

	#Apply the JavaOpts configuration (if any) - I know this is not ideal to be editing the RUN_CMD parameter
	#however I expect this will be deprecated as soon as Bamboo moves away from Jetty.
	print "Applying Java_Opts configuration to install...\n\n";
	updateJavaOpts(
		$globalConfig->param( $lcApplication . ".installDir" )
		  . "/bamboo.sh",
		"RUN_CMD",
		$globalConfig->param( $lcApplication . ".javaParams" )
	);

	print "Configuration settings have been applied successfully.\n\n";

	#Run any additional steps
	$WrapperDownloadFile =
	  downloadFileAndChown( $globalConfig->param("$lcApplication.installDir"),
		$WrapperDownloadUrlFor64Bit, $osUser );

	rmtree(
		[ $globalConfig->param("$lcApplication.installDir") . "/wrapper" ] );

	extractAndMoveDownload( $WrapperDownloadFile,
		$globalConfig->param("$lcApplication.installDir") . "/wrapper",
		$osUser, "" );

	#Generate the init.d file
	print
"Setting up initd files and run as a service (if configured) please wait...\n\n";
	$log->info("$subname: Generating init.d file for $application.");

	generateInitD(
		$lcApplication, $osUser,
		$globalConfig->param("$lcApplication.installDir"),
		"bamboo.sh start",
		"bamboo.sh stop"
	);

	#Finally run generic post install tasks
	postInstallGeneric($application);
}

########################################
#InstallGeneric                        #
########################################
sub installGeneric {
	my $input;
	my $mode;
	my $version;
	my $application;
	my $lcApplication;
	my @downloadDetails;
	my $downloadArchivesUrl;
	my @requiredConfigItems;
	my $archiveLocation;
	my $osUser;
	my $VERSIONLOOP = 1;
	my @uidGid;
	my $serverPortAvailCode;
	my $connectorPortAvailCode;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	$application         = $_[0];
	$downloadArchivesUrl = $_[1];
	@requiredConfigItems = @{ $_[2] };

	$lcApplication = lc($application);

#Iterate through required config items, if an are missing force an update of configuration
	if ( checkRequiredConfigItems(@requiredConfigItems) eq "FAIL" ) {
		$log->info(
"$subname: Some of the config parameters are invalid or null. Forcing generation"
		);
		print
"Some of the $application config parameters are incomplete. You must review the $application configuration before continuing: \n\n";
		generateApplicationConfig( $application, "UPDATE", $globalConfig );
		$log->info("Writing out config file to disk.");
		$globalConfig->write($configFile);
		loadSuiteConfig();
	}

	#Otherwise provide the option to update the configuration before proceeding
	else {
		print
"Would you like to review the $application config before installing? Yes/No [yes]: ";

		$input = getBooleanInput();
		print "\n";
		if ( $input eq "default" || $input eq "yes" ) {
			$log->info(
				"$subname: User opted to update config prior to installation."
			);
			generateApplicationConfig( $application, "UPDATE", $globalConfig );
			$log->info("Writing out config file to disk.");
			$globalConfig->write($configFile);
			loadSuiteConfig();
		}
	}

	#Get the user the application will run as
	$osUser = $globalConfig->param("$lcApplication.osUser");

	#Check the user exists or create if not
	createOSUser($osUser);

	$serverPortAvailCode =
	  isPortAvailable( $globalConfig->param("lcApplication.serverPort") );

	$connectorPortAvailCode =
	  isPortAvailable( $globalConfig->param("lcApplication.connectorPort") );

	if ( $serverPortAvailCode == 0 || $connectorPortAvailCode == 0 ) {
		$log->info(
"$subname: ServerPortAvailCode=$serverPortAvailCode, ConnectorPortAvailCode=$connectorPortAvailCode. Whichever one equals 0 
is currently in use. We will continue however there is a good chance $application will not start."
		);
		print
"One or more of the ports configured for $application are currently in use. We can proceed however there is a very good chance"
		  . " that $application will not start correctly.\n\n";
		print
"Would you like to continue even though the ports are in use? yes/no [yes]: ";

		$input = getBooleanInput();
		print "\n";
		if ( $input eq "no" ) {
			$log->logdie(
"User selected NO as ports are in use: Install will not proceed. Exiting script. \n\n"
			);
		}
		else {
			$log->info(
				"$subname: User opted to continue even though ports are in use."
			);
		}

	}

	print "Would you like to install the latest version? yes/no [yes]: ";

	$input = getBooleanInput();
	print "\n";
	if ( $input eq "default" || $input eq "yes" ) {
		$log->info(
			"$subname: User opted to install latest version of $application");
		$mode = "LATEST";
	}
	else {
		$log->info(
			"$subname: User opted to install specific version of $application"
		);
		$mode = "SPECIFIC";
	}

	#If a specific version is selected, ask for the version number
	if ( $mode eq "SPECIFIC" ) {
		while ( $VERSIONLOOP == 1 ) {
			print
			  "Please enter the version number you would like. i.e. 4.2.2 []: ";

			$version = <STDIN>;
			print "\n";
			chomp $version;
			dumpSingleVarToLog( "$subname" . "_versionEntered", $version );

			#Check that the input version actually exists
			print
"Please wait, checking that version $version of $application exists (may take a few moments)... \n\n";

			#get the version specific URL to test
			@downloadDetails =
			  getVersionDownloadURL( $lcApplication, $globalArch, $version );

			#Try to get the header of the version URL to ensure it exists
			if ( head( $downloadDetails[0] ) ) {
				$log->info(
"$subname: User selected to install version $version of $application"
				);
				$VERSIONLOOP = 0;
				print "$application version $version found. Continuing...\n\n";
			}
			else {
				$log->warn(
"$subname: User selected to install version $version of $application. No such version exists, asking for input again."
				);
				print
"No such version of $application exists. Please visit $downloadArchivesUrl and pick a valid version number and try again.\n\n";
			}
		}

	}

	#Download the latest version
	if ( $mode eq "LATEST" ) {
		$log->info("$subname: Downloading latest version of $application");
		@downloadDetails =
		  downloadAtlassianInstaller( $mode, $lcApplication, "", $globalArch );
		$version = $downloadDetails[1];

	}

	#Download a specific version
	else {
		$log->info("$subname: Downloading version $version of $application");
		@downloadDetails =
		  downloadAtlassianInstaller( $mode, $lcApplication, $version,
			$globalArch );
	}

	#Extract the download and move into place
	$log->info("$subname: Extracting $downloadDetails[2]...");
	extractAndMoveDownload( $downloadDetails[2],
		$globalConfig->param("$lcApplication.installDir"),
		$osUser, "" );

	#Check if user wants to remove the downloaded archive
	print "Do you wish to delete the downloaded archive "
	  . $downloadDetails[2]
	  . "? [yes]: ";
	$input = getBooleanInput();
	print "\n";
	if ( $input eq "default" || $input eq "yes" ) {
		$log->info("$subname: User opted to delete downloaded installer.");
		unlink $downloadDetails[2]
		  or warn "Could not delete " . $downloadDetails[2] . ": $!";
	}

	#Update config to reflect new version that is installed
	$log->info("$subname: Writing new installed version to the config file.");
	$globalConfig->param( "$lcApplication.installedVersion", $version );
	$log->info("Writing out config file to disk.");
	$globalConfig->write($configFile);
	loadSuiteConfig();

#If MySQL is the Database, Atlassian apps do not come with the driver so copy it
	if ( $globalConfig->param("general.targetDBType") eq "MySQL" ) {
		$log->info(
"$subname: Copying MySQL JDBC connector to $application install directory."
		);
		createAndChownDirectory(
			$globalConfig->param("$lcApplication.installDir")
			  . $globalConfig->param("$lcApplication.tomcatDir") . "/lib/",
			$osUser
		);
		print
"Database is configured as MySQL, copying the JDBC connector to $application install.\n\n";
		copyFile( $globalConfig->param("general.dbJDBCJar"),
			    $globalConfig->param("$lcApplication.installDir")
			  . $globalConfig->param("$lcApplication.tomcatDir")
			  . "/lib/" );

		#Chown the files again
		$log->info( "$subname: Chowning "
			  . $globalConfig->param( $lcApplication . ".installDir" ) . "/lib/"
			  . " to $osUser following MySQL JDBC install." );
		chownRecursive( $osUser,
			    $globalConfig->param("$lcApplication.installDir")
			  . $globalConfig->param("$lcApplication.tomcatDir")
			  . "/lib/" );
	}

	#Create home/data directory if it does not exist
	$log->info(
"$subname: Checking for and creating $application home directory (if it does not exist)."
	);
	print
"Checking if data directory exists and creating if not, please wait...\n\n";
	createAndChownDirectory( $globalConfig->param("$lcApplication.dataDir"),
		$osUser );

	#GenericInstallCompleted
}

########################################
#PostInstallGeneric                    #
########################################
sub postInstallGeneric {
	my $application;
	my $lcApplication;
	my $input;
	my $osUser;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	$application = $_[0];

	$lcApplication = lc($application);
	$osUser        = $globalConfig->param("$lcApplication.osUser");

	#If set to run as a service, set to run on startup
	if ( $globalConfig->param("$lcApplication.runAsService") eq "TRUE" ) {
		$log->info(
			"$subname: Setting up $application as a service to run on startup."
		);
		manageService( "INSTALL", $lcApplication );
	}
	print "Services configured successfully.\n\n";

	#Check if we should start the service
	print
"Installation has completed successfully. Would you like to start the $application service now? Yes/No [yes]: ";
	$input = getBooleanInput();
	print "\n";
	if ( $input eq "default" || $input eq "yes" ) {
		$log->info("$subname: User opted to start application service.");
		system("service $lcApplication start");
		print "\n"
		  . "$application can now be accessed on http://localhost:"
		  . $globalConfig->param("$lcApplication.connectorPort")
		  . getConfigItem( "$lcApplication.appContext", $globalConfig )
		  . ".\n\n";
		print "If you have any issues please check the \n\n";
	}

}

########################################
#UpgradeCrowd                          #
########################################
sub upgradeCrowd {
	my $input;
	my $mode;
	my $version;
	my $application = "crowd";
	my $lcApplication;
	my @downloadDetails;
	my @downloadVersionCheck;
	my $archiveLocation;
	my $osUser;
	my $VERSIONLOOP = 1;
	my @uidGid;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");
	$lcApplication = lc($application);

	#Set up list of config items that are requred for this install to run
	my @requiredConfigItems;
	@requiredConfigItems = (
		"crowd.appContext",    "crowd.enable",
		"crowd.dataDir",       "crowd.installDir",
		"crowd.runAsService",  "crowd.serverPort",
		"crowd.connectorPort", "crowd.osUser"
	);

#Iterate through required config items, if an are missing force an update of configuration
	if ( checkRequiredConfigItems(@requiredConfigItems) eq "FAIL" ) {
		$log->info(
"$subname: Some of the config parameters are invalid or null. Forcing generation"
		);
		print
"Some of the Crowd config parameters are incomplete. You must review the Crowd configuration before continuing: \n\n";
		generateCrowdConfig( "UPDATE", $globalConfig );
		$log->info("Writing out config file to disk.");
		$globalConfig->write($configFile);
		loadSuiteConfig();
	}

	#Otherwise provide the option to update the configuration before proceeding
	else {
		print
"Would you like to review the Crowd config before upgrading? Yes/No [yes]: ";

		$input = getBooleanInput();
		print "\n";
		if ( $input eq "default" || $input eq "yes" ) {
			$log->info(
				"$subname: User opted to update config prior to installation."
			);
			generateCrowdConfig( "UPDATE", $globalConfig );
			$log->info("Writing out config file to disk.");
			$globalConfig->write($configFile);
			loadSuiteConfig();
		}
	}

	#Set up list of config items that are requred for this install to run
	@requiredConfigItems = ("crowd.installedVersion");

#Iterate through required config items, if an are missing force an update of configuration
	if ( checkRequiredConfigItems(@requiredConfigItems) eq "FAIL" ) {
		genConfigItem(
			$mode,
			$globalConfig,
			"crowd.installedVersion",
"There is no version listed in the config file for the currently installed version of Crowd . Please enter the version of Crowd that is CURRENTLY installed.",
			""
		);
		$log->info("Writing out config file to disk.");
		$globalConfig->write($configFile);
		loadSuiteConfig();
	}

	#Get the user Crowd will run as
	$osUser = $globalConfig->param("crowd.osUser");

	#Check the user exists or create if not
	createOSUser($osUser);

	#We are upgrading, get the latest version
	print "Would you like to upgrade to the latest version? yes/no [yes]: ";

	$input = getBooleanInput();
	print "\n";
	if ( $input eq "default" || $input eq "yes" ) {
		$log->info(
			"$subname: User opted to install latest version of $application");
		$mode = "LATEST";
	}
	else {
		$log->info(
			"$subname: User opted to install specific version of $application"
		);
		$mode = "SPECIFIC";
	}

	#If a specific version is selected, ask for the version number
	if ( $mode eq "SPECIFIC" ) {
		while ( $VERSIONLOOP == 1 ) {
			print
			  "Please enter the version number you would like. i.e. 4.2.2 []: ";

			$version = <STDIN>;
			print "\n";
			chomp $version;
			dumpSingleVarToLog( "$subname" . "_versionEntered", $version );

			#Check that the input version actually exists
			print
"Please wait, checking that version $version of Crowd exists (may take a few moments)... \n\n";

			#get the version specific URL to test
			@downloadDetails =
			  getVersionDownloadURL( $application, $globalArch, $version );

			#Try to get the header of the version URL to ensure it exists
			if ( head( $downloadDetails[0] ) ) {
				$log->info(
"$subname: User selected to install version $version of $application"
				);
				$VERSIONLOOP = 0;
				print "Crowd version $version found. Continuing...\n\n";
			}
			else {
				$log->warn(
"$subname: User selected to install version $version of $application. No such version exists, asking for input again."
				);
				print
"No such version of Crowd exists. Please visit http://www.atlassian.com/software/crowd/download-archive and pick a valid version number and try again.\n\n";
			}
		}

	}

	#Get the URL for the version we want to download
	if ( $mode eq "LATEST" ) {
		@downloadVersionCheck =
		  getLatestDownloadURL( $application, $globalArch );
		my $versionSupported =
		  compareTwoVersions( $globalConfig->param("crowd.installedVersion"),
			$downloadVersionCheck[1] );
		if ( $versionSupported eq "GREATER" ) {
			$log->logdie( "The version to be downloaded ("
				  . $downloadVersionCheck[1]
				  . ") is older than the currently installed version ("
				  . $globalConfig->param("crowd.installedVersion")
				  . "). Downgrading is not supported and this script will now exit.\n\n"
			);
		}
	}
	elsif ( $mode eq "SPECIFIC" ) {
		my $versionSupported =
		  compareTwoVersions( $globalConfig->param("crowd.installedVersion"),
			$version );
		if ( $versionSupported eq "GREATER" ) {
			$log->logdie( "The version to be downloaded (" 
				  . $version
				  . ") is older than the currently installed version ("
				  . $globalConfig->param("crowd.installedVersion")
				  . "). Downgrading is not supported and this script will now exit.\n\n"
			);
		}
	}

	#Download the latest version
	if ( $mode eq "LATEST" ) {
		$log->info("$subname: Downloading latest version of $application");
		@downloadDetails =
		  downloadAtlassianInstaller( $mode, $application, "", $globalArch );

	}

	#Download a specific version
	else {
		$log->info("$subname: Downloading version $version of $application");
		@downloadDetails =
		  downloadAtlassianInstaller( $mode, $application, $version,
			$globalArch );
	}

	#Prompt user to stop existing service
	$log->info("$subname: Stopping existing $application service...");
	print
"We will now stop the existing Crowd service, please press enter to continue...";
	$input = <STDIN>;
	print "\n";
	if ( -e "/etc/init.d/crowd" ) {
		system("service crowd stop")
		  or $log->logdie("Could not stop Crowd: $!");
	}
	else {
		if ( -e $globalConfig->param("crowd.installDir") . "/stop_crowd.sh" ) {
			system( $globalConfig->param("crowd.installDir")
				  . "/stop_crowd.sh" )
			  or $log->logdie(
"Unable to stop Crowd service, unable to continue please stop manually and try again...\n\n"
			  );
		}
		else {
			$log->logdie(
"Unable to find current Crowd installation to stop the service.\nPlease check the Crowd configuration and try again"
			);
		}
	}

	#Extract the download and move into place
	$log->info("$subname: Extracting $downloadDetails[2]...");
	extractAndMoveDownload( $downloadDetails[2],
		$globalConfig->param("crowd.installDir"),
		$osUser, "UPGRADE" );

	#Check if user wants to remove the downloaded archive
	print "Do you wish to delete the downloaded archive "
	  . $downloadDetails[2]
	  . "? [yes]: ";
	$input = getBooleanInput();
	print "\n";
	if ( $input eq "default" || $input eq "yes" ) {
		$log->info("$subname: User opted to delete downloaded installer.");
		unlink $downloadDetails[2]
		  or warn "Could not delete " . $downloadDetails[2] . ": $!";
	}

	#Update config to reflect new version that is installed
	$log->info("$subname: Writing new installed version to the config file.");
	$globalConfig->param( "crowd.installedVersion", $version );
	$log->info("Writing out config file to disk.");
	$globalConfig->write($configFile);
	loadSuiteConfig();

#If MySQL is the Database, Atlassian apps do not come with the driver so copy it
	if ( $globalConfig->param("general.targetDBType") eq "MySQL" ) {
		$log->info(
"$subname: Copying MySQL JDBC connector to $application install directory."
		);
		print
"Database is configured as MySQL, copying the JDBC connector to Crowd install.\n\n";
		copyFile( $globalConfig->param("general.dbJDBCJar"),
			    $globalConfig->param("$lcApplication.installDir")
			  . $globalConfig->param("$lcApplication.tomcatDir")
			  . "/lib/" );

		#Chown the files again
		$log->info( "$subname: Chowning "
			  . $globalConfig->param( $lcApplication . ".installDir" ) . "/lib/"
			  . " to $osUser following MySQL JDBC install." );
		chownRecursive( $osUser,
			$globalConfig->param("crowd.installDir") . "/apache-tomcat/lib/" );
	}

	print "Applying configuration settings to the install, please wait...\n\n";

	print "Creating backup of config files...\n\n";
	$log->info("$subname: Backing up config files.");

	backupFile(
		$globalConfig->param("crowd.installDir")
		  . "/apache-tomcat/conf/server.xml",
		$osUser
	);

	backupFile(
		$globalConfig->param("crowd.installDir")
		  . "/crowd-webapp/WEB-INF/classes/crowd-init.properties",
		$osUser
	);

	print "Applying port numbers to server config...\n\n";

	#Update the server config with the configured connector port
	$log->info( "$subname: Updating the connector port in "
		  . $globalConfig->param("$lcApplication.installDir")
		  . "/conf/server.xml" );
	updateXMLAttribute(
		$globalConfig->param("crowd.installDir")
		  . "/apache-tomcat/conf/server.xml",
		"///Connector", "port", $globalConfig->param("crowd.connectorPort")
	);

	#Update the server config with the configured server port
	$log->info( "$subname: Updating the server port in "
		  . $globalConfig->param("$lcApplication.installDir")
		  . "/conf/server.xml" );
	updateXMLAttribute(
		$globalConfig->param("crowd.installDir")
		  . "/apache-tomcat/conf/server.xml",
		"/Server", "port", $globalConfig->param("crowd.serverPort")
	);

	#Apply application context
	$log->info( "$subname: Applying application context to "
		  . $globalConfig->param("$lcApplication.installDir")
		  . "/conf/server.xml" );
	print "Applying application context to config...\n\n";
	updateXMLAttribute(
		$globalConfig->param("crowd.installDir")
		  . "/apache-tomcat/conf/server.xml",
		"//////Context",
		"path",
		getConfigItem( "crowd.appContext", $globalConfig )
	);

	print "Applying home directory location to config...\n\n";

	#Edit Crowd config file to reference homedir
	$log->info( "$subname: Applying homedir to"
		  . $globalConfig->param("$lcApplication.installDir")
		  . " in /conf/server.xml" );

	updateLineInFile(
		$globalConfig->param("crowd.installDir")
		  . "/crowd-webapp/WEB-INF/classes/crowd-init.properties",
		"crowd.home",
		"crowd.home=" . $globalConfig->param("crowd.dataDir"),
		"#crowd.home=/var/crowd-home"
	);

	print "Configuration settings have been applied successfully.\n\n";

	#Set up init.d again just incase any params have changed.
	print
"Setting up initd files and run as a service (if configured) please wait...\n\n";

	#Generate the init.d file
	generateInitD( $application, $osUser,
		$globalConfig->param("crowd.installDir"),
		"start_crowd.sh", "stop_crowd.sh" );

	#If set to run as a service, set to run on startup
	if ( $globalConfig->param("crowd.runAsService") eq "TRUE" ) {
		$log->info("$subname: Setting up as a service to run on startup.");
		manageService( "INSTALL", $application );
	}
	print "Services configured successfully.\n\n";

	#Check if we should start the service
	print
"Upgrade has completed successfully. Would you like to Start the Crowd service now? Yes/No [yes]: ";
	$input = getBooleanInput();
	print "\n";
	if ( $input eq "default" || $input eq "yes" ) {
		$log->info("$subname: User opted to start application service.");
		system("service $application start");
		print "\nCrowd can now be accessed on http://localhost:"
		  . $globalConfig->param("crowd.connectorPort")
		  . getConfigItem( "crowd.appContext", $globalConfig ) . ".\n\n";
		print "If you have any issues please check the log at "
		  . $globalConfig->param("crowd.installDir")
		  . "/apache-tomcat/logs/catalina.out\n\n";
	}
}

########################################
#Uninstall Crowd                       #
########################################
sub uninstallCrowd {
	my $application = "crowd";
	my $initdFile   = "/etc/init.d/$application";
	my $input;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	print
"This will uninstall Crowd. This will delete the installation directory AND provide the option to delete the data directory.\n";
	print
"You have been warned, proceed only if you have backed up your installation as there is no turning back.\n\n";
	print "Do you really want to continue? yes/no [no]: ";

	$input = getBooleanInput();
	print "\n";
	if ( $input eq "yes" ) {
		$log->info("$subname: User selected to uninstall $application");

		#Remove Service
		print "Disabling service...\n\n";
		$log->info("$subname: Disabling $application service");
		manageService( "UNINSTALL", $application );

		#remove init.d file
		print "Removing init.d file\n\n";
		$log->info( "$subname: Removing $application" . "'s init.d file" );
		unlink $initdFile or warn "Could not unlink $initdFile: $!";

		#Remove install dir
		print "Removing installation directory...\n\n";
		$log->info(
			"$subname: Removing " . $globalConfig->param("crowd.installDir") );
		if ( -d $globalConfig->param("crowd.installDir") ) {
			rmtree( [ $globalConfig->param("crowd.installDir") ] );
		}
		else {
			$log->warn( "$subname: Unable to remove "
				  . $globalConfig->param("crowd.installDir")
				  . ". Directory does not exist." );
			print
"Could not find configured install directory... possibly not installed?";
		}

		#Check if you REALLY want to remove data directory
		print
"We will now remove the data directory (Crowd home directory). Are you REALLY REALLY REALLY REALLY sure you want to do this? (not recommended) yes/no [no]: \n";
		$input = getBooleanInput();
		print "\n";
		if ( $input eq "yes" ) {
			$log->info( "$subname: User selected to delete "
				  . $globalConfig->param("crowd.dataDir")
				  . ". Deleting." );
			rmtree( [ $globalConfig->param("crowd.dataDir") ] );
		}
		else {
			$log->info(
"$subname: User opted to keep the $application data directory at "
				  . $globalConfig->param("crowd.dataDir")
				  . "." );
			print
"The data directory has not been deleted and is still available at "
			  . $globalConfig->param("crowd.dataDir") . ".\n\n";
		}

		#Update config to null out the Crowd config
		$log->info(
			"$subname: Nulling out the installed version of $application.");
		$globalConfig->param( "crowd.installedVersion", "" );
		$globalConfig->param( "crowd.enable",           "FALSE" );
		$log->info("Writing out config file to disk.");
		$globalConfig->write($configFile);
		loadSuiteConfig();

		print
"Crowd has been uninstalled successfully and the config file updated to reflect Crowd as disabled. Press enter to continue...\n\n";
		$input = <STDIN>;
	}
}

########################################
#GenerateJiraConfig                    #
########################################
sub generateJiraConfig {
	my $cfg;
	my $mode;
	my $defaultValue;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");
	$mode = $_[0];
	$cfg  = $_[1];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_mode", $mode );

	genConfigItem(
		$mode, $cfg, "jira.installDir",
		"Please enter the directory Jira will be installed into.",
		$cfg->param("general.rootInstallDir") . "/jira"
	);

	genConfigItem(
		$mode, $cfg, "jira.dataDir",
		"Please enter the directory Jira's data will be stored in.",
		$cfg->param("general.rootDataDir") . "/jira"
	);

	genConfigItem(
		$mode,
		$cfg,
		"jira.appContext",
"Enter the context that Jira should run under (i.e. /jira or /bugtraq). Write NULL to blank out the context.",
		"/jira"
	);

	genConfigItem(
		$mode,
		$cfg,
		"jira.connectorPort",
"Please enter the Connector port Jira will run on (note this is the port you will access in the browser).",
		"8080"
	);

	checkConfiguredPort( "jira.connectorPort", $cfg );

	genConfigItem(
		$mode,
		$cfg,
		"jira.serverPort",
"Please enter the SERVER port Jira will run on (note this is the control port not the port you access in a browser).",
		"8000"
	);

	checkConfiguredPort( "jira.serverPort", $cfg );

	genConfigItem(
		$mode,
		$cfg,
		"jira.javaParams",
"Enter any additional paramaters you would like to add to the Java RUN_OPTS.",
		""
	);

	genConfigItem(
		$mode,
		$cfg,
		"jira.javaMinMemory",
		"Enter the minimum amount of memory you would like to assign to Jira.",
		"256m"
	);

	genConfigItem(
		$mode,
		$cfg,
		"jira.javaMaxMemory",
		"Enter the maximum amount of memory you would like to assign to Jira.",
		"768m"
	);

	genConfigItem(
		$mode,
		$cfg,
		"jira.javaMaxPermSize",
"Enter the amount of memory for the MAX_PERM_SIZE parameter that you would like to assign to Jira.",
		"256m"
	);

	genBooleanConfigItem( $mode, $cfg, "jira.runAsService",
		"Would you like to run Jira as a service? yes/no.", "yes" );

}

########################################
#GenerateCrowdConfig                   #
########################################
sub generateCrowdConfig {
	my $cfg;
	my $mode;
	my $defaultValue;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	$mode = $_[0];
	$cfg  = $_[1];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_mode", $mode );

	genConfigItem(
		$mode,
		$cfg,
		"crowd.installDir",
		"Please enter the directory Crowd will be installed into.",
		$cfg->param("general.rootInstallDir") . "/crowd"
	);

	genConfigItem(
		$mode, $cfg, "crowd.dataDir",
		"Please enter the directory Crowd's data will be stored in.",
		$cfg->param("general.rootDataDir") . "/crowd"
	);

	genConfigItem( $mode, $cfg, "crowd.osUser",
		"Enter the user that Crowd will run under.", "crowd" );

	genConfigItem(
		$mode,
		$cfg,
		"crowd.appContext",
"Enter the context that Crowd should run under (i.e. /crowd or /login). Write NULL to blank out the context.",
		"/crowd"
	);
	genConfigItem(
		$mode,
		$cfg,
		"crowd.connectorPort",
"Please enter the Connector port Crowd will run on (note this is the port you will access in the browser).",
		"8095"
	);
	checkConfiguredPort( "crowd.connectorPort", $cfg );

	genConfigItem(
		$mode,
		$cfg,
		"crowd.serverPort",
"Please enter the SERVER port Crowd will run on (note this is the control port not the port you access in a browser).",
		"8000"
	);
	checkConfiguredPort( "crowd.serverPort", $cfg );

	genConfigItem(
		$mode,
		$cfg,
		"crowd.javaParams",
"Enter any additional paramaters you would like to add to the Java RUN_OPTS.",
		""
	);

	genConfigItem(
		$mode,
		$cfg,
		"crowd.javaMinMemory",
		"Enter the minimum amount of memory you would like to assign to Crowd.",
		"128m"
	);

	genConfigItem(
		$mode,
		$cfg,
		"crowd.javaMaxMemory",
		"Enter the maximum amount of memory you would like to assign to Crowd.",
		"512m"
	);

	genConfigItem(
		$mode,
		$cfg,
		"crowd.javaMaxPermSize",
"Enter the amount of memory for the MAX_PERM_SIZE parameter that you would like to assign to Crowd.",
		"256m"
	);

	genBooleanConfigItem( $mode, $cfg, "crowd.runAsService",
		"Would you like to run Crowd as a service? yes/no.", "yes" );

	#Set up some defaults for Crowd
	$cfg->param( "crowd.tomcatDir", "/apache-tomcat" );
	$cfg->param( "crowd.webappDir", "/crowd-webapp" );

}

########################################
#GenerateFisheyeConfig                 #
########################################
sub generateFisheyeConfig {
	my $cfg;
	my $mode;
	my $defaultValue;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	$mode = $_[0];
	$cfg  = $_[1];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_mode", $mode );

	genConfigItem(
		$mode,
		$cfg,
		"fisheye.installDir",
		"Please enter the directory Fisheye will be installed into.",
		$cfg->param("general.rootInstallDir") . "/fisheye"
	);

	genConfigItem(
		$mode,
		$cfg,
		"fisheye.dataDir",
		"Please enter the directory Fisheye's data will be stored in.",
		$cfg->param("general.rootDataDir") . "/fisheye"
	);

	genConfigItem( $mode, $cfg, "fisheye.osUser",
		"Enter the user that Fisheye will run under.", "fisheye" );

	genConfigItem(
		$mode,
		$cfg,
		"fisheye.appContext",
"Enter the context that Fisheye should run under (i.e. /fisheye). Write NULL to blank out the context.",
		"/fisheye"
	);

	genConfigItem(
		$mode,
		$cfg,
		"fisheye.connectorPort",
"Please enter the Connector port Fisheye will run on (note this is the port you will access in the browser).",
		"8060"
	);
	checkConfiguredPort( "fisheye.connectorPort", $cfg );

	genConfigItem(
		$mode,
		$cfg,
		"fisheye.serverPort",
"Please enter the SERVER port Fisheye will run on (note this is the control port not the port you access in a browser).",
		"8059"
	);
	checkConfiguredPort( "fisheye.serverPort", $cfg );

	genConfigItem(
		$mode,
		$cfg,
		"fisheye.javaParams",
"Enter any additional paramaters you would like to add to the Java RUN_OPTS.",
		""
	);

	genConfigItem(
		$mode,
		$cfg,
		"fisheye.javaMinMemory",
"Enter the minimum amount of memory you would like to assign to Fisheye.",
		"128m"
	);

	genConfigItem(
		$mode,
		$cfg,
		"fisheye.javaMaxMemory",
"Enter the maximum amount of memory you would like to assign to Fisheye.",
		"512m"
	);

	genConfigItem(
		$mode,
		$cfg,
		"fisheye.javaMaxPermSize",
"Enter the amount of memory for the MAX_PERM_SIZE parameter that you would like to assign to Fisheye.",
		"256m"
	);

	genBooleanConfigItem( $mode, $cfg, "fisheye.runAsService",
		"Would you like to run Fisheye as a service? yes/no.", "yes" );

	#Set up some defaults for Fisheye
	$cfg->param( "fisheye.tomcatDir", "" )
	  ;    #we leave these blank deliberately due to the way Fishey works
	$cfg->param( "fisheye.webappDir", "" )
	  ;    #we leave these blank deliberately due to the way Fishey works

}

########################################
#GenerateConfluenceConfig              #
########################################
sub generateConfluenceConfig {
	my $cfg;
	my $mode;
	my $defaultValue;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	$mode = $_[0];
	$cfg  = $_[1];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_mode", $mode );

	genConfigItem(
		$mode,
		$cfg,
		"confluence.installDir",
		"Please enter the directory Confluence will be installed into.",
		$cfg->param("general.rootInstallDir") . "/confluence"
	);
	genConfigItem(
		$mode,
		$cfg,
		"confluence.dataDir",
		"Please enter the directory Confluence's data will be stored in.",
		$cfg->param("general.rootDataDir") . "/confluence"
	);
	genConfigItem(
		$mode,
		$cfg,
		"confluence.appContext",
"Enter the context that Confluence should run under (i.e. /wiki or /confluence). Write NULL to blank out the context.",
		"/confluence"
	);
	genConfigItem(
		$mode,
		$cfg,
		"confluence.connectorPort",
"Please enter the Connector port Confluence will run on (note this is the port you will access in the browser).",
		"8090"
	);
	checkConfiguredPort( "confluence.connectorPort", $cfg );

	genConfigItem(
		$mode,
		$cfg,
		"confluence.serverPort",
"Please enter the SERVER port Confluence will run on (note this is the control port not the port you access in a browser).",
		"8000"
	);

	checkConfiguredPort( "confluence.serverPort", $cfg );

	genConfigItem(
		$mode,
		$cfg,
		"confluence.javaParams",
"Enter any additional paramaters you would like to add to the Java RUN_OPTS.",
		""
	);

	genConfigItem(
		$mode,
		$cfg,
		"confluence.javaMinMemory",
"Enter the minimum amount of memory you would like to assign to Confluence.",
		"256m"
	);

	genConfigItem(
		$mode,
		$cfg,
		"confluence.javaMaxMemory",
"Enter the maximum amount of memory you would like to assign to Confluence.",
		"512m"
	);

	genConfigItem(
		$mode,
		$cfg,
		"confluence.javaMaxPermSize",
"Enter the amount of memory for the MAX_PERM_SIZE parameter that you would like to assign to Confluence.",
		"256m"
	);

	genBooleanConfigItem( $mode, $cfg, "confluence.runAsService",
		"Would you like to run Confluence as a service? yes/no.", "yes" );

}

########################################
#GenerateBambooConfig                  #
########################################
sub generateBambooConfig {
	my $cfg;
	my $mode;
	my $defaultValue;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	$mode = $_[0];
	$cfg  = $_[1];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_mode", $mode );

	genConfigItem(
		$mode,
		$cfg,
		"bamboo.installDir",
		"Please enter the directory Bamboo will be installed into.",
		$cfg->param("general.rootInstallDir") . "/bamboo"
	);
	genConfigItem(
		$mode,
		$cfg,
		"bamboo.dataDir",
		"Please enter the directory Bamboo's data will be stored in.",
		$cfg->param("general.rootDataDir") . "/bamboo"
	);
	genConfigItem( $mode, $cfg, "bamboo.osUser",
		"Enter the user that Bamboo will run under.", "bamboo" );
	genConfigItem(
		$mode,
		$cfg,
		"bamboo.appContext",
"Enter the context that Bamboo should run under (i.e. /bamboo). Write NULL to blank out the context.",
		"/bamboo"
	);
	genConfigItem(
		$mode,
		$cfg,
		"bamboo.connectorPort",
"Please enter the Connector port Bamboo will run on (note this is the port you will access in the browser).",
		"8085"
	);
	checkConfiguredPort( "bamboo.connectorPort", $cfg );

#	genConfigItem(
#		$mode,
#		$cfg,
#		"confluence.serverPort",
#"Please enter the SERVER port Confluence will run on (note this is the control port not the port you access in a browser).",
#		"8000"
#	);
#
#	checkConfiguredPort( "confluence.serverPort", $cfg );

	genConfigItem(
		$mode,
		$cfg,
		"bamboo.javaParams",
"Enter any additional paramaters you would like to add to the Java RUN_OPTS.",
		""
	);

	genConfigItem(
		$mode,
		$cfg,
		"bamboo.javaMinMemory",
"Enter the minimum amount of memory you would like to assign to Bamboo.",
		"256m"
	);

	genConfigItem(
		$mode,
		$cfg,
		"bamboo.javaMaxMemory",
"Enter the maximum amount of memory you would like to assign to Bamboo.",
		"512m"
	);

	genConfigItem(
		$mode,
		$cfg,
		"bamboo.javaMaxPermSize",
"Enter the amount of memory for the MAX_PERM_SIZE parameter that you would like to assign to Bamboo.",
		"256m"
	);

	genBooleanConfigItem( $mode, $cfg, "bamboo.runAsService",
		"Would you like to run Bamboo as a service? yes/no.", "yes" );

}

########################################
#GenerateStashConfig                   #
########################################
sub generateStashConfig {
	my $cfg;
	my $mode;
	my $defaultValue;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	$mode = $_[0];
	$cfg  = $_[1];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_mode", $mode );

	genConfigItem(
		$mode,
		$cfg,
		"stash.installDir",
		"Please enter the directory Stash will be installed into.",
		$cfg->param("general.rootInstallDir") . "/stash"
	);
	genConfigItem(
		$mode, $cfg, "stash.dataDir",
		"Please enter the directory Stash's data will be stored in.",
		$cfg->param("general.rootDataDir") . "/stash"
	);
	genConfigItem( $mode, $cfg, "stash.osUser",
		"Enter the user that Stash will run under.", "stash" );
	genConfigItem(
		$mode,
		$cfg,
		"stash.appContext",
"Enter the context that Stash should run under (i.e. /stash). Write NULL to blank out the context.",
		"/stash"
	);
	genConfigItem(
		$mode,
		$cfg,
		"stash.connectorPort",
"Please enter the Connector port Stash will run on (note this is the port you will access in the browser).",
		"8085"
	);
	checkConfiguredPort( "stash.connectorPort", $cfg );

	genConfigItem(
		$mode,
		$cfg,
		"stash.serverPort",
"Please enter the SERVER port Stash will run on (note this is the control port not the port you access in a browser).",
		"8000"
	);

	checkConfiguredPort( "stash.serverPort", $cfg );

	genConfigItem(
		$mode,
		$cfg,
		"stash.javaParams",
"Enter any additional paramaters you would like to add to the Java RUN_OPTS.",
		""
	);

	genConfigItem(
		$mode,
		$cfg,
		"stash.javaMinMemory",
		"Enter the minimum amount of memory you would like to assign to Stash.",
		"512m"
	);

	genConfigItem(
		$mode,
		$cfg,
		"stash.javaMaxMemory",
		"Enter the maximum amount of memory you would like to assign to Stash.",
		"768m"
	);

	genConfigItem(
		$mode,
		$cfg,
		"stash.javaMaxPermSize",
"Enter the amount of memory for the MAX_PERM_SIZE parameter that you would like to assign to Stash.",
		"256m"
	);

	genBooleanConfigItem( $mode, $cfg, "stash.runAsService",
		"Would you like to run Stash as a service? yes/no.", "yes" );

	#Set up some defaults for Crowd
	$cfg->param( "stash.tomcatDir", "" );
	$cfg->param( "stash.webappDir", "/atlassian-stash" );

}

########################################
#Download Atlassian Installer          #
########################################
sub downloadAtlassianInstaller {
	my $type;
	my $product;
	my $version;
	my $downloadURL;
	my $architecture;
	my $parsedURL;
	my @downloadDetails;
	my $input;
	my $downloadResponseCode;
	my $absoluteFilePath;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	$type         = $_[0];
	$product      = $_[1];
	$version      = $_[2];
	$architecture = $_[3];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_type",         $type );
	dumpSingleVarToLog( "$subname" . "_product",      $product );
	dumpSingleVarToLog( "$subname" . "_version",      $version );
	dumpSingleVarToLog( "$subname" . "_architecture", $architecture );

	print "Beginning download of $product, please wait...\n\n";

	#Get the URL for the version we want to download
	if ( $type eq "LATEST" ) {
		$log->debug("$subname: Downloading latest version of $product");
		@downloadDetails = getLatestDownloadURL( $product, $architecture );
	}
	else {
		$log->debug("$subname: Downloading version $version of $product");
		@downloadDetails =
		  getVersionDownloadURL( $product, $architecture, $version );
	}
	dumpSingleVarToLog( "$subname" . "_downloadDetails[0]",
		$downloadDetails[0] );
	dumpSingleVarToLog( "$subname" . "_downloadDetails[1]",
		$downloadDetails[1] );

	#Check if we are trying to download a supported version
	if ( isSupportedVersion( $product, $downloadDetails[1] ) eq "no" ) {
		$log->warn(
"$subname: Version $version of $product is has not been fully tested with this script."
		);
		print
"This version of $product ($downloadDetails[1]) has not been fully tested with this script. Do you wish to continue?: [yes]";

		$input = getBooleanInput();
		dumpSingleVarToLog( "$subname" . "_input", $input );
		print "\n";
		if ( $input eq "no" ) {
			$log->logdie(
"User opted not to continue as the version is not supported, please try again with a specific version which is supported, or check for an update to this script."
			);
		}
		else {
			$log->info(
"$subname: User has opted to download $version of $product even though it has not been tested with this script."
			);
		}
	}

	#Parse the URL so that we can get specific sections of it
	$parsedURL = URI->new( $downloadDetails[0] );
	my @bits = $parsedURL->path_segments();

	#Set the download to show progress as we download
	$ua->show_progress(1);

	#Check that the install/download directory exists, if not create it
	print "Checking that root install dir exists...\n\n";
	createDirectory( $globalConfig->param("general.rootInstallDir") );

	$absoluteFilePath =
	  $globalConfig->param("general.rootInstallDir") . "/" . $bits[ @bits - 1 ];
	dumpSingleVarToLog( "$subname" . "_absoluteFilePath", $absoluteFilePath );

#Check if local file already exists and if it does, provide the option to skip downloading
	if ( -e $absoluteFilePath ) {
		$log->debug(
			"$subname: The install file $absoluteFilePath already exists.");
		print "The local install file "
		  . $absoluteFilePath
		  . " already exists. Would you like to skip re-downloading the file: [yes]";

		$input = getBooleanInput();
		dumpSingleVarToLog( "$subname" . "_input", $input );
		print "\n";
		if ( $input eq "yes" || $input eq "default" ) {
			$log->debug(
"$subname: User opted to skip redownloading the installer file for $product."
			);
			$downloadDetails[2] =
			    $globalConfig->param("general.rootInstallDir") . "/"
			  . $bits[ @bits - 1 ];
			return @downloadDetails;
		}
	}
	else {
		$log->debug("$subname: Beginning download.");

		#Download the file and store the HTTP response code
		print "Downloading file from Atlassian...\n\n";
		$downloadResponseCode = getstore( $downloadDetails[0],
			    $globalConfig->param("general.rootInstallDir") . "/"
			  . $bits[ @bits - 1 ] );
		dumpSingleVarToLog( "$subname" . "_downloadResponseCode",
			$downloadResponseCode );

#Test if the download was a success, if not die and return HTTP response code otherwise return the absolute path to file
		if ( is_success($downloadResponseCode) ) {
			$log->debug(
"$subname: Download completed successfully with HTTP response code $downloadResponseCode."
			);
			print "\n";
			print "Download completed successfully.\n\n";
			$downloadDetails[2] =
			    $globalConfig->param("general.rootInstallDir") . "/"
			  . $bits[ @bits - 1 ];
			return @downloadDetails;
		}
		else {
			$log->logdie(
"Could not download $product version $version. HTTP Response received was: '$downloadResponseCode'"
			);
		}
	}

}

########################################
#Download Full Suite                   #
#Please note this is REALLY only for   #
#testing purposes not for any real     #
#production use.                       #
########################################
sub downloadLatestAtlassianSuite {
	my $downloadURL;
	my $architecture;
	my $parsedURL;
	my @downloadDetails;
	my @suiteProducts;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	$architecture = $_[0];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_architecture", $architecture );

	#Configure all products in the suite
	@suiteProducts =
	  ( 'crowd', 'confluence', 'jira', 'fisheye', 'bamboo', 'stash' );

	#Iterate through each of the products, get the URL and download
	foreach (@suiteProducts) {
		@downloadDetails = getLatestDownloadURL( $_, $architecture );

		$parsedURL = URI->new( $downloadDetails[0] );
		my @bits = $parsedURL->path_segments();
		$ua->show_progress(1);

		getstore( $downloadDetails[0],
			    $globalConfig->param("general.rootInstallDir") . "/"
			  . $bits[ @bits - 1 ] );
	}

}

########################################
#Download File and Chown               #
########################################
sub downloadFileAndChown {
	my $destinationDir;    #This function assumes this directory already exists.
	my $downloadURL;
	my $architecture;
	my $parsedURL;
	my $input;
	my $downloadResponseCode;
	my $absoluteFilePath;
	my $osUser;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	$destinationDir = $_[0];
	$downloadURL    = $_[1];
	$osUser         = $_[2];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_destinationDir", $destinationDir );
	dumpSingleVarToLog( "$subname" . "_downloadURL",    $downloadURL );
	dumpSingleVarToLog( "$subname" . "_osUser",         $osUser );

	print "Beginning download of $downloadURL please wait...\n\n";

	#Parse the URL so that we can get specific sections of it
	$parsedURL = URI->new($downloadURL);
	my @bits = $parsedURL->path_segments();

	#Set the download to show progress as we download
	$ua->show_progress(1);

	$absoluteFilePath = $destinationDir . "/" . $bits[ @bits - 1 ];
	dumpSingleVarToLog( "$subname" . "_absoluteFilePath", $absoluteFilePath );

#Check if local file already exists and if it does, provide the option to skip downloading
	if ( -e $absoluteFilePath ) {
		$log->debug(
			"$subname: The download file $absoluteFilePath already exists.");
		print "The local download file "
		  . $absoluteFilePath
		  . " already exists. Would you like to skip re-downloading the file: [yes]";

		$input = getBooleanInput();
		dumpSingleVarToLog( "$subname" . "_input", $input );
		print "\n";
		if ( $input eq "yes" || $input eq "default" ) {
			$log->debug(
"$subname: User opted to skip redownloading the file $downloadURL."
			);
			chownFile( $osUser, $absoluteFilePath );
			return $absoluteFilePath;
		}
	}
	else {
		$log->debug("$subname: Beginning download.");

		#Download the file and store the HTTP response code
		print "Downloading file $downloadURL...\n\n";
		$downloadResponseCode = getstore( $downloadURL, $absoluteFilePath );
		dumpSingleVarToLog( "$subname" . "_downloadResponseCode",
			$downloadResponseCode );

#Test if the download was a success, if not die and return HTTP response code otherwise return the absolute path to file
		if ( is_success($downloadResponseCode) ) {
			$log->debug(
"$subname: Download completed successfully with HTTP response code $downloadResponseCode."
			);
			print "\n";
			print "Download completed successfully.\n\n";
			chownFile( $osUser, $absoluteFilePath );
			return $absoluteFilePath;
		}
		else {
			$log->logdie(
"Could not download $downloadURL. HTTP Response received was: '$downloadResponseCode'"
			);
		}
	}

}

########################################
#GenerateSuiteConfig                   #
########################################
sub generateSuiteConfig {
	my $cfg;
	my $mode;
	my $input;
	my $defaultValue;
	my @parameterNull;
	my $oldConfig;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	#Check if we have a valid config file already, if so we are updating it
	if ($globalConfig) {
		$log->info(
"$subname: globalConfig is defined therefore we are performing an update."
		);
		$mode      = "UPDATE";
		$cfg       = $globalConfig;
		$oldConfig = new Config::Simple($configFile);
	}

	#Otherwise we are creating a new file
	else {
		$log->info(
"$subname: globalConfig is undefined therefore we are creating a new config file from scratch."
		);
		$mode = "NEW";
		$cfg = new Config::Simple( syntax => 'ini' );
	}

	#Generate Main Suite Configuration
	print
"This will guide you through the generation of the config required for the management of the Atlassian suite.\n\n";

	#Check for 64Bit Override
	if ( testOSArchitecture() eq "64" ) {
		genBooleanConfigItem(
			$mode,
			$cfg,
			"general.force32Bit",
			"Your operating system architecture has been detected as "
			  . testOSArchitecture()
			  . "bit. Would you prefer to override this and force 32 bit installs (not recommended)? yes/no",
			"no"
		);
	}

	#Get root installation directory
	genConfigItem( $mode, $cfg, "general.rootInstallDir",
		"Please enter the root directory the suite will be installed into.",
		"/opt/atlassian" );

	#Get root data directory
	genConfigItem(
		$mode,
		$cfg,
		"general.rootDataDir",
"Please enter the root directory the suite data/home directories will be stored.",
		"/var/atlassian/application-data"
	);

	#Get Crowd configuration
	genBooleanConfigItem( $mode, $cfg, "crowd.enable",
		"Do you wish to install/manage Crowd? yes/no ", "yes" );

	if ( $cfg->param("crowd.enable") eq "TRUE" ) {
		print
		  "Do you wish to set up/update the Crowd configuration now? [no]: ";

		$input = getBooleanInput();

		if ( $input eq "yes" ) {
			print "\n";
			generateCrowdConfig( $mode, $cfg );
		}

	}

	#Get Jira configuration
	genBooleanConfigItem( $mode, $cfg, "jira.enable",
		"Do you wish to install/manage Jira? yes/no ", "yes" );

	if ( $cfg->param("jira.enable") eq "TRUE" ) {
		print "Do you wish to set up/update the Jira configuration now? [no]: ";

		$input = getBooleanInput();

		if ( $input eq "yes" ) {
			print "\n";
			generateJiraConfig( $mode, $cfg );
		}
	}

	#Get Confluence configuration
	genBooleanConfigItem( $mode, $cfg, "confluence.enable",
		"Do you wish to install/manage Confluence? yes/no ", "yes" );

	if ( $cfg->param("confluence.enable") eq "TRUE" ) {
		print
"Do you wish to set up/update the Confluence configuration now? [no]: ";

		$input = getBooleanInput();

		if ( $input eq "yes" ) {
			print "\n";
			generateConfluenceConfig( $mode, $cfg );
		}
	}

	#Get Fisheye configuration
	genBooleanConfigItem( $mode, $cfg, "fisheye.enable",
		"Do you wish to install/manage Fisheye? yes/no ", "yes" );

	if ( $cfg->param("fisheye.enable") eq "TRUE" ) {
		print
		  "Do you wish to set up/update the Fisheye configuration now? [no]: ";

		$input = getBooleanInput();

		if ( $input eq "yes" ) {
			print "\n";
			generateFisheyeConfig( $mode, $cfg );
		}
	}

	#Get Bamboo configuration
	genBooleanConfigItem( $mode, $cfg, "bamboo.enable",
		"Do you wish to install/manage Bamboo? yes/no ", "yes" );

	if ( $cfg->param("bamboo.enable") eq "TRUE" ) {
		print
		  "Do you wish to set up/update the Bamboo configuration now? [no]: ";

		$input = getBooleanInput();

		if ( $input eq "yes" ) {
			print "\n";
			generateBambooConfig( $mode, $cfg );
		}
	}

	#Get Stash configuration
	genBooleanConfigItem( $mode, $cfg, "stash.enable",
		"Do you wish to install/manage Stash? yes/no ", "yes" );

	if ( $cfg->param("stash.enable") eq "TRUE" ) {
		print
		  "Do you wish to set up/update the Stash configuration now? [no]: ";

		$input = getBooleanInput();

		if ( $input eq "yes" ) {
			print "\n";
			generateStashConfig( $mode, $cfg );
		}
	}

	#Get suite database architecture configuration
	@parameterNull = $cfg->param("general.targetDBType");

	if ( $mode eq "UPDATE" ) {
		if ( !( $#parameterNull == -1 ) ) {
			$defaultValue = $cfg->param("general.targetDBType");
		}
		else {
			$defaultValue = "";
		}
	}
	else {
		$defaultValue = "";
	}
	print
"What is the target database type that will be used (enter number to select)? 1/2/3/4/5 ["
	  . $defaultValue . "] :";
	print "\n1. MySQL";
	print "\n2. PostgreSQL";
	print "\n3. Oracle";
	print "\n4. Microsoft SQL Server";
	print "\n5. HSQLDB (NOT RECOMMENDED/Even for testing purposes!)";
	if ( !( $#parameterNull == -1 ) ) {
		print
"\n\nPlease make a selection: (note hitting RETURN will keep existing value of ["
		  . $defaultValue . "].";
	}
	else {
		print "\n\nPlease make a selection: ";
	}

	my $LOOP = 1;

	while ( $LOOP == 1 ) {

		$input = <STDIN>;
		chomp $input;
		dumpSingleVarToLog( "$subname" . "_inputEntered", $input );
		print "\n";

		if (   ( lc $input ) eq "1"
			|| ( lc $input ) eq "mysql" )
		{
			$log->info("$subname: Database arch selected is MySQL");
			$LOOP = 0;
			$cfg->param( "general.targetDBType", "MySQL" );
		}
		elsif (( lc $input ) eq "2"
			|| ( lc $input ) eq "postgresql"
			|| ( lc $input ) eq "postgres"
			|| ( lc $input ) eq "postgre" )
		{
			$log->info("$subname: Database arch selected is PostgreSQL");
			$LOOP = 0;
			$cfg->param( "general.targetDBType", "PostgreSQL" );
		}
		elsif (( lc $input ) eq "3"
			|| ( lc $input ) eq "oracle" )
		{
			$log->info("$subname: Database arch selected is Oracle");
			$LOOP = 0;
			$cfg->param( "general.targetDBType", "Oracle" );
		}
		elsif (( lc $input ) eq "4"
			|| ( lc $input ) eq "microsoft sql server"
			|| ( lc $input ) eq "mssql" )
		{
			$log->info("$subname: Database arch selected is MSSQL");
			$LOOP = 0;
			$cfg->param( "general.targetDBType", "MSSQL" );
		}
		elsif (( lc $input ) eq "5"
			|| ( lc $input ) eq "hsqldb"
			|| ( lc $input ) eq "hsql" )
		{
			$log->info("$subname: Database arch selected is HSQLDB");
			$LOOP = 0;
			$cfg->param( "general.targetDBType", "HSQLDB" );
		}
		elsif ( ( lc $input ) eq "" & ( $#parameterNull == -1 ) ) {
			$log->warn(
"$subname: User made NULL selection with no previous value entered."
			);
			print
			  "You did not make a selection please enter 1, 2, 3, 4 or 5. \n\n";
		}
		elsif ( ( lc $input ) eq "" & !( $#parameterNull == -1 ) ) {
			$log->info(
"$subname: User just pressed return therefore existing datbase selection will be kept."
			);

			#keepExistingValueWithNoChange
			$LOOP = 0;
		}
		else {
			$log->info(
"$subname: User did not enter valid input for database selection. Asking for input again."
			);
			print "Your input '" . $input
			  . "'was not recognised. Please try again and enter either 1, 2, 3, 4 or 5. \n\n";
		}
	}
	if ( defined($oldConfig) ) {
		if ( $cfg->param("general.targetDBType") ne
			$oldConfig->param("general.targetDBType") )
		{
			$log->info(
"$subname: Database selection has changed from previous config. Nulling out JDBC config option to ensure it gets set correctly if needed."
			);

#Database selection has changed therefore NULL the dbJDBCJar config option to ensure it gets a new value appropriate to the new DB
			$cfg->param( "general.dbJDBCJar", "" );
		}
	}
	@parameterNull = $cfg->param("general.dbJDBCJar");

	if ( $cfg->param("general.targetDBType") eq "MySQL" &
		( $#parameterNull == -1 ) )
	{
		$log->info(
"$subname: MySQL has been selected and no valid JDBC entry defined in config. Download MySQL JDBC driver."
		);
		downloadJDBCConnector( "MySQL", $cfg );
	}
	if (
		(
			   $cfg->param("general.targetDBType") eq "Oracle"
			|| $cfg->param("general.targetDBType") eq "MSSQL"
		) &
		( ( $#parameterNull == -1 ) || $cfg->param("general.dbJDBCJar") eq "" )
	  )
	{

		#createNullOptionInConfigFile
		$cfg->param( "general.dbJDBCJar", "" );
		print "In order to support your target database type ["
		  . $cfg->param("general.targetDBType")
		  . "] you need to download the appropriate JAR file.\n\n";

		if ( $cfg->param("general.targetDBType") eq "Oracle" ) {
			print
"Please visit http://www.oracle.com/technetwork/database/features/jdbc/index-091264.html and download the appropriate JDBC JAR File\n";
		}
		elsif ( $cfg->param("general.targetDBType") eq "MSSQL" ) {
			print
"Please visit http://msdn.microsoft.com/en-us/sqlserver/aa937724.aspx and download the appropriate JDBC JAR File\n";
		}
		print
"Once you have downloaded this (any location is fine, I recommend to the folder this script is installed into),\nplease edit the 'dbJDBCJar' option under [general] in '$configFile' to point to the full absolute path (including filename) of the jar file.\n\n";
		print
"This script will now exit. Please update the aforementioned config before running again.\n\n";

		#Write config and exit;
		$log->info("Writing out config file to disk and terminating script.");
		$cfg->write($configFile);
		exit;
	}

	#Write config and reload
	$log->info("Writing out config file to disk.");
	$cfg->write($configFile);
	loadSuiteConfig();
	$globalArch = whichApplicationArchitecture();
}

########################################
#Display Install Menu                  #
########################################
sub displayMenu {
	my $choice;
	my $main_menu;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	my $LOOP = 1;
	while ( $LOOP == 1 ) {

		# define the main menu as a multiline string
		$main_menu = <<'END_TXT';

      Welcome to the Atlassian Suite Manager Script

      AtlassianSuiteManager Copyright (C) 2012-2013  Stuart Ryan
      
      ###########################################################################################
      I would like to thank Atlassian for providing me with complimentary OpenSource licenses to
      CROWD, JIRA, Fisheye, Confluence, Greenhopper and Team Calendars for Confluence
    
      I would also like to say a massive thank you to Turnkey Internet (www.turnkeyinternet.net)
      for sponsoring me with significantly discounted hosting without which I would not have been
      able to write, and continue hosting the Atlassian Suite for my open source projects and
      this script.
      ###########################################################################################
      
      This program comes with ABSOLUTELY NO WARRANTY;
      This is free software, and you are welcome to redistribute it
      under certain conditions; read the COPYING file included for details.


      Please select from the following options:

      1) Install Jira
      2) Install Confluence
      3) Install Bamboo
      4) Uninstall Jira
      5) Uninstall Confluence
      D) Download Latest Atlassian Suite FULL (Testing & Debugging)
      Q) Quit

END_TXT

		# print the main menu
		system 'clear';
		print $main_menu;

		# prompt for user's choice
		printf( "%s", "enter selection: " );

		# capture the choice
		$choice = <STDIN>;
		dumpSingleVarToLog( "$subname" . "_choiceEntered", $choice );

		# and finally print it
		#print "You entered: ",$choice;
		if ( $choice eq "Q\n" || $choice eq "q\n" ) {
			system 'clear';
			$LOOP = 0;
			exit 0;
		}
		elsif ( $choice eq "1\n" ) {
			system 'clear';
			installJira();
		}
		elsif ( $choice eq "2\n" ) {
			system 'clear';
			installConfluence();
		}
		elsif ( lc($choice) eq "d\n" ) {
			system 'clear';
			downloadLatestAtlassianSuite($globalArch);
		}
		elsif ( lc($choice) eq "3\n" ) {
			system 'clear';
			installBamboo();
		}
		elsif ( lc($choice) eq "4\n" ) {
			system 'clear';
			uninstallJira();
		}
		elsif ( lc($choice) eq "5\n" ) {
			system 'clear';
			uninstallConfluence();
		}
		elsif ( lc($choice) eq "t\n" ) {
			system 'clear';
			updateLineInBambooWrapperConf(
				"/opt/atlassian/bamboo/conf/wrapper.conf",
				"wrapper.java.additional.", "-Xma", "512m" );
		}
	}
}
bootStrapper();

#generateSuiteConfig();

#getVersionDownloadURL( "confluence", $globalArch, "4.2.7" );

#updateJavaOpts ("/opt/atlassian/confluence/bin/setenv.sh", "-Djavax.net.ssl.trustStore=/usr/java/default/jre/lib/security/cacerts");

#print isSupportedVersion( "confluence", "4.3.3" );

#backupFile( "/opt/atlassian/confluence/bin",
#	"/opt/atlassian/confluence/bin", "setenv.sh" );

#generateInitD("crowd","crowd",$globalConfig->param("confluence.installDir"),"start_crowd.sh","stop_crowd.sh");

#updateLineInFile( "crowd.cfg", "crowd.home",
#	"crowd.home=" . $globalConfig->param("crowd.dataDir"),
#	"#crowd.home=/var/crowd-home" );

#extractAndMoveDownload( "/opt/atlassian/software/atlassian-crowd-2.5.2.tar.gz",
#	$globalConfig->param("crowd.installDir") );

#extractAndMoveDownload( "/opt/atlassian/atlassian-crowd-2.5.1.tar.gz",
#	  "/opt/atlassian/stu", "crowd" );

#installCrowd();
#installFisheye();

#updateXMLAttribute( "/opt/atlassian/fisheyestu/config.xml", "web-server", "context",
#		"/fisheye" );

#downloadAtlassianInstaller( "SPECIFIC", "crowd", "2.5.2",
#	$globalArch );
#downloadJDBCConnector("PostgreSQL");

#upgradeCrowd();

#uninstallCrowd();

#print compareTwoVersions("5.1.1","5.1.1");

#installJira();

#upgradeJira();

#installConfluence();

#print getUserCreatedByInstaller("jira.installDir","JIRA_USER") . "\n\n";
#print isPortAvailable("22");

#dumpSingleVarToLog( "var1", "varvalue" );
#downloadLatestAtlassianSuite( $globalArch );
#print downloadFileAndChown(
#	"/opt/atlassian",
#"https://confluence.atlassian.com/download/attachments/289276785/Bamboo_64_Bit_Wrapper.zip?version=1&modificationDate=1346435557878&api=v2",
#	"fisheye"
#);
displayMenu();
