#!/usr/bin/perl

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
#
#    I would also like to say a massive thank you to Turnkey Internet (www.turnkeyinternet.net)
#    for sponsoring me with significantly discounted hosting without which I would not have been
#    able to write, and continue hosting the Atlassian Suite for my open source projects and
#    this script.
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

use Net::SSLGlue::LWP;    #Added to resolve [#ATLASMGR-378]
use LWP::Simple qw($ua getstore get is_success head);
use JSON qw( decode_json );    # From CPAN
use JSON qw( from_json );      # From CPAN
use URI;                       # From CPAN
use POSIX qw(strftime);
use Data::Dumper;              # Perl core module
use Config::Simple;            # From CPAN
use File::Copy;
use File::Copy::Recursive qw(fcopy rcopy dircopy fmove rmove dirmove);
use File::Path qw(make_path remove_tree);
use File::Path;
use File::Find;
use File::Basename;
use Archive::Extract;
use FindBin '$Bin';
use XML::Twig;
use Socket qw( PF_INET SOCK_STREAM INADDR_ANY sockaddr_in );
use Errno qw( EADDRINUSE );
use Getopt::Long;
use Log::Log4perl;
use Filesys::DfPortable;
use ExtUtils::Installed;
use strict;      # Good practice
use warnings;    # Good practice

Getopt::Long::Configure("bundling");
Log::Log4perl->init("log4j.conf");

########################################
#Set Up Variables                      #
########################################
my $globalConfig;
my $scriptVersion = "0-2-7"
  ; #we use a dash here to replace .'s as Config::Simple kinda cries with a . in the group name
my $supportedVersionsConfig;
my $configFile                  = "settings.cfg";
my $supportedVersionsConfigFile = "supportedVersions.cfg";
my $distro;
my $silent                  = '';     #global flag for command line parameters
my $debug                   = '';     #global flag for command line parameters
my $unsupported             = '';     #global flag for command line parameters
my $ignore_version_warnings = '';     #global flag for command line parameters
my $disable_config_checks   = '';     #global flag for command line parameters
my $verbose                 = '';     #global flag for command line parameters
my $autoMode                = '';     #global flag for command line parameters
my $enableEAPDownloads      = '0';    #global flag for command line parameters
my $globalArch;
my $logFile;
my @suiteApplications =
  ( "Bamboo", "Confluence", "Crowd", "Fisheye", "JIRA", "Stash" );
my %latestVersions  = ();
my %appsWithUpdates = ();
my $availableUpdatesString;
my $latestVersionsCacheFile = "$Bin/working/latestVersions.cache";
my $log                     = Log::Log4perl->get_logger("");
my $hostnameRegex           = qr/^([-a-zA-Z0-9\.]*)$/;
$Archive::Extract::PREFER_BIN = 1;

#######################################################################
#BEGIN SUPPORTING FUNCTIONS                                           #
#######################################################################

########################################
#BackupApplication                     #
#Backs up both an application and its  #
#data directories prior to an upgrade  #
########################################
sub backupApplication {
	my $date = strftime "%Y%m%d_%H%M%S", localtime;
	my $originalDir;
	my $osUser;
	my $applicationDirBackupDirName;
	my $dataDirBackupDirName;
	my $application;
	my $lcApplication;
	my $size           = 0;
	my $installDirSize = 0;
	my $dataDirSize    = 0;
	my $installDirRef;
	my $dataDirRef;
	my $installDriveFreeSpace;
	my $dataDriveFreeSpace;
	my $installDirFolder;
	my $dataDirPath;
	my $installDirPath;
	my $dataDirFolder;
	my ($fd);
	my $compressBackups = $globalConfig->param("general.compressBackups");
	my $subname         = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	$application   = $_[0];
	$lcApplication = lc($application);

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_application",     $application );
	dumpSingleVarToLog( "$subname" . "_compressBackups", $compressBackups );

	#set up some parameters
	$installDirFolder =
	  basename(
		escapeFilePath( $globalConfig->param("$lcApplication.installDir") ) );
	$dataDirFolder =
	  basename(
		escapeFilePath( $globalConfig->param("$lcApplication.dataDir") ) );
	$installDirPath =
	  dirname(
		escapeFilePath( $globalConfig->param("$lcApplication.installDir") ) );
	$dataDirPath =
	  dirname(
		escapeFilePath( $globalConfig->param("$lcApplication.dataDir") ) );

	print
"Please wait, backing up your existing application (this may take a few moments)...\n\n";

	#Checking that the service is stopped for good measure
	if (
		stopService(
			$application,
			"\""
			  . $globalConfig->param(
				$lcApplication . ".processSearchParameter1"
			  )
			  . "\"",
			"\""
			  . $globalConfig->param(
				$lcApplication . ".processSearchParameter2"
			  )
			  . "\""
		) eq "FAIL"
	  )
	{
		$log->warn(
"$subname: Could not stop $application successfully. This may cause issues if you attempt to restore."
		);
		warn
"Could not stop $application successfully. PLEASE NOTE!!! There is no way to verify the integrity of the backup if the application is running at the time of backup: $!\n\n";
	}

	#Check that we have enough disk space
	$installDirSize =
	  getDirSize(
		escapeFilePath( $globalConfig->param("$lcApplication.installDir") ) );
	$dataDirSize =
	  getDirSize(
		escapeFilePath( $globalConfig->param("$lcApplication.dataDir") ) );

	$installDirRef =
	  dfportable(
		escapeFilePath( $globalConfig->param("$lcApplication.installDir") ) );
	$dataDirRef =
	  dfportable(
		escapeFilePath( $globalConfig->param("$lcApplication.dataDir") ) );

	$installDriveFreeSpace = $installDirRef->{bfree};
	$dataDriveFreeSpace    = $dataDirRef->{bfree};

	#dump values if we are in debug
	dumpSingleVarToLog( "$subname" . "_installDirSize", $installDirSize );
	dumpSingleVarToLog( "$subname" . "_dataDirSize",    $dataDirSize );
	dumpSingleVarToLog( "$subname" . "_installDriveFreeSpace",
		$installDriveFreeSpace );
	dumpSingleVarToLog( "$subname" . "_dataDriveFreeSpace", $installDirSize );
	dumpSingleVarToLog( "$subname" . "_installDirRef",      $installDirRef );
	dumpSingleVarToLog( "$subname" . "_dataDirRef",         $dataDirRef );

#check if the free space, minus install dir size minus a 500MB buffer is less than zero
	if ( $installDriveFreeSpace - $installDirSize - 524288000 < 0 ) {
		$log->logdie(
			"There is not enough space on the drive containing "
			  . escapeFilePath(
				$globalConfig->param("$lcApplication.installDir")
			  )
			  . " to create a backup of the install directory for $application. Please free up space and then try again."
		);
	}

#we deliberately leave the installDirSize param in here as it is the smaller of the two and may reside on the same drive.
#we also add a 500MB buffer for safety.
	if ( $dataDriveFreeSpace - $installDirSize - $dataDirSize - 524288000 < 0 )
	{
		$log->logdie( "There is not enough space on the drive containing "
			  . escapeFilePath( $globalConfig->param("$lcApplication.dataDir") )
			  . " to create a backup of the data directory for $application. Please free up space and then try again."
		);
	}

	$applicationDirBackupDirName =
	    escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
	  . "_backup_"
	  . $date;
	$dataDirBackupDirName =
	    escapeFilePath( $globalConfig->param("$lcApplication.dataDir") )
	  . "_backup_"
	  . $date;
	$log->info(
"$subname: Backing up the $application application directory to $applicationDirBackupDirName"
	);

	if ( $compressBackups eq "TRUE" ) {
		$log->info("$subname: Compressing $applicationDirBackupDirName");
		print
"You have selected to compress application backups... Compressing $application installation directory to a backup, this may take a few minutes...\n\n";
		system( "cd $installDirPath && tar -czf "
			  . $applicationDirBackupDirName
			  . ".tar.gz "
			  . $installDirFolder );
		if ( $? != 0 ) {
			print "\n\n";
			$log->warn(
"$subname: Compression did not complete succesfully, proceeding with standard uncompressed directory as the backup location."
			);
			print
"Compression did not complete succesfully, proceeding with standard uncompressed directory as the backup location.: \n\n";
			print
"Backing up $application installation directory uncompressed...\n\n";
			copyDirectory(
				escapeFilePath(
					$globalConfig->param("$lcApplication.installDir")
				),
				$applicationDirBackupDirName
			);
			$globalConfig->param(
				"$lcApplication.latestInstallDirBackupLocation",
				$applicationDirBackupDirName );
			print
"$application installation successfully backed up to $applicationDirBackupDirName. \n\n";
		}
		else {
			print "\n\n";
			$globalConfig->param(
				"$lcApplication.latestInstallDirBackupLocation",
				$applicationDirBackupDirName . ".tar.gz"
			);
			print
"$application installation successfully backed up to $applicationDirBackupDirName.tar.gz \n\n";
		}
	}
	else {
		print "Backing up $application installation directory...\n\n";
		copyDirectory(
			escapeFilePath( $globalConfig->param("$lcApplication.installDir") ),
			$applicationDirBackupDirName
		);
		$globalConfig->param( "$lcApplication.latestInstallDirBackupLocation",
			$applicationDirBackupDirName );
		print
"$application installation successfully backed up to $applicationDirBackupDirName. \n\n";
	}

	if ( $compressBackups eq "TRUE" ) {
		$log->info("$subname: Compressing $dataDirBackupDirName");
		print
"You have selected to compress application backups... Compressing $application data directory to a backup, for large installations this may take some time...\n\n";
		system( "cd $dataDirPath && tar -czf "
			  . $dataDirBackupDirName
			  . ".tar.gz "
			  . $dataDirFolder );
		if ( $? != 0 ) {
			print "\n\n";
			$log->warn(
"$subname: Compression did not complete succesfully, proceeding with standard uncompressed directory as the backup location."
			);
			print
"Compression did not complete succesfully, proceeding with standard uncompressed directory as the backup location.: \n\n";
			print
"Backing up $application installation directory uncompressed...\n\n";
			copyDirectory(
				escapeFilePath(
					$globalConfig->param("$lcApplication.dataDir")
				),
				$dataDirBackupDirName
			);
			$globalConfig->param( "$lcApplication.latestDataDirBackupLocation",
				$dataDirBackupDirName );
			print
"$application installation successfully backed up to $applicationDirBackupDirName. \n\n";
		}
		else {
			print "\n\n";
			$globalConfig->param( "$lcApplication.latestDataDirBackupLocation",
				$dataDirBackupDirName . ".tar.gz" );
			print
"$application data directory successfully backed up to $dataDirBackupDirName.tar.gz \n\n";
		}
	}
	else {
		print "Backing up $application data directory...\n\n";
		copyDirectory(
			escapeFilePath( $globalConfig->param("$lcApplication.dataDir") ),
			$dataDirBackupDirName );
		$globalConfig->param( "$lcApplication.latestDataDirBackupLocation",
			$dataDirBackupDirName );
		print
"$application data directory successfully backed up to $dataDirBackupDirName. \n\n";
	}

	print "Tidying up... please wait... \n\n";

	$log->info(
"Writing out config file to disk following new application backup being taken."
	);
	$globalConfig->write($configFile);
	loadSuiteConfig();

	$log->info(
"$subname: Doing recursive chown of $applicationDirBackupDirName and $dataDirBackupDirName to "
		  . $globalConfig->param("$lcApplication.osUser")
		  . "." );

	chownRecursive( $globalConfig->param("$lcApplication.osUser"),
		$globalConfig->param("$lcApplication.latestInstallDirBackupLocation") );
	chownRecursive( $globalConfig->param("$lcApplication.osUser"),
		$globalConfig->param("$lcApplication.latestDataDirBackupLocation") );

	print "A backup of $application has been taken successfully.\n\n";
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

	$log->debug("BEGIN: $subname");

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
	$log->info("$subname: Doing recursive chown of $backupDirName to $osUser");
	chownRecursive( $osUser, $backupDirName );
}

########################################
#backupFile                            #
########################################
sub backupFile {
	my $inputFile;
	my $osUser;
	my $date = strftime "%Y%m%d_%H%M%S", localtime;
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

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
#checkASMPatchLevel                    #
########################################
sub checkASMPatchLevel {
	my @parameterNull;
	my $patchLevel;
	my $applicationToCheck;
	my $lcApplicationToCheck;
	my $configResult;

	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	#check if there is a corresponding version in settings.cfg

	@parameterNull = $globalConfig->param("general.asmPatchLevel");
	if ( ( $#parameterNull == -1 )
		|| $globalConfig->param("general.asmPatchLevel") eq "" )
	{
		$log->info(
"$subname: No ASM patch level currently exists in the settings file."
		);
		$patchLevel =
		  "0-0-0";    #set patch level to 0 to apply all previous patches
	}
	else {
		$patchLevel = $globalConfig->param("general.asmPatchLevel");
	}

	if ( compareTwoVersions( $patchLevel, $scriptVersion ) eq "LESS" ) {
		if ( compareTwoVersions( $patchLevel, "0-2-3" ) eq "LESS" ) {
			$log->info("$subname: Applying patchlevel 0.2.3 to current config");

			#previous bugfixes being migrated into this new tool
			#Apply fix for [#ATLASMGR-317]
			foreach (@suiteApplications) {
				$applicationToCheck   = $_;
				$lcApplicationToCheck = lc($applicationToCheck);

				@parameterNull =
				  $globalConfig->param("$lcApplicationToCheck.apacheProxySSL");
				if ( !( $#parameterNull == -1 ) ) {
					$configResult = $globalConfig->param(
						"$lcApplicationToCheck.apacheProxySSL");

					if ( $configResult eq "https" ) {
						$globalConfig->param(
							"$lcApplicationToCheck.apacheProxySSL", "TRUE" );
					}
					elsif ( $configResult eq "http" ) {
						$globalConfig->param(
							"$lcApplicationToCheck.apacheProxySSL", "FALSE" );
					}
				}
			}

			#End Fix for [#ATLASMGR-317]
			#end previous bugfixes

			#bugfixes for v0.2.3 release
			#Begin fix for [#ATLASMGR-381]

			foreach (@suiteApplications) {
				$applicationToCheck   = $_;
				$lcApplicationToCheck = lc($applicationToCheck);

				if ( -e "/etc/init.d/$lcApplicationToCheck" ) {
					chmod 0755, "/etc/init.d/$lcApplicationToCheck"
					  or $log->warn(
						"Couldn't chmod /etc/init.d/$lcApplicationToCheck: $!");
				}

			}

			#Generate the new Atlassian Init.D Script
			generateInitDforSuite();

			#End Fix for [#ATLASMGR-381]

			#set new patch level version
			$globalConfig->param( "general.asmPatchLevel", "0-2-3" );

			#Write config and reload
			$log->info("Writing out config file to disk.");
			$globalConfig->write($configFile);
			loadSuiteConfig();

		}

	   #insert any later version patches here to apply them in the correct order

#apply current script version number to file after all patchlevels have been met
		$globalConfig->param( "general.asmPatchLevel", $scriptVersion );

		#Write config and reload
		$log->info("Writing out config file to disk.");
		$globalConfig->write($configFile);
		loadSuiteConfig();

	}
	else {
		$log->info("$subname: Patchlevel is up to date");
	}
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
	my @portTestReturn;
	my $application;
	my $lcApplication;
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");
	$application = $_[0];
	$configItem  = $_[1];

	if ( defined( $_[2] ) ) {
		$cfg = $_[2];
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
				"",
				'^([0-9]*)$',
"The port number you entered contained invalid characters. Please ensure you enter only digits.\n\n"
			);
		}
		else {
			$availCode = isPortAvailable($configValue);
			dumpSingleVarToLog(
				"Port $configValue availability: $availCode (1=AVAIL/0=INUSE)",
				$availCode
			);

			if ( $availCode == 1 ) {
				@portTestReturn =
				  isPortDefinedElsewhere( $application, $configValue );
				if ( scalar @portTestReturn == 0 ) {
					$log->info("Port is available.");
					$LOOP = 0;
				}
				else {
					print
"That port is currently configured by one or more other applications in settings.cfg (listed below). You should enter a different port: \n\n";
					foreach (@portTestReturn) {
						print $_ . "\n";
					}
					print "\n";

					$log->info("Port is in use.");

					$input = getBooleanInput(
"Would you like to configure a different port? yes/no [yes]: "
					);
					print "\n";
					if (   $input eq "yes"
						|| $input eq "default" )
					{
						$log->info("User selected to configure new port.");
						genConfigItem(
							"UPDATE",
							$cfg,
							$configItem,
							"Please enter the new port number to configure",
							"",
							'^([0-9]*)$',
"The port number you entered contained invalid characters. Please ensure you enter only digits.\n\n"
						);
					}
					elsif ( $input eq "no" ) {
						$LOOP = 0;
						$log->info("User selected to keep existing port.");
					}
				}
			}
			else {
				$log->info("Port is in use.");

				$input = getBooleanInput(
"The port you have configured ($configValue) for $configItem is currently in use, this may be expected if you are already running the application."
					  . "\nOtherwise you may need to configure another port.\n\nWould you like to configure a different port? yes/no [yes]: "
				);
				print "\n";
				if (   $input eq "yes"
					|| $input eq "default" )
				{
					$log->info("User selected to configure new port.");
					genConfigItem(
						"UPDATE",
						$cfg,
						$configItem,
						"Please enter the new port number to configure",
						"",
						'^([0-9]*)$',
"The port number you entered contained invalid characters. Please ensure you enter only digits.\n\n"
					);

				}
				elsif ( $input eq "no" ) {
					$LOOP = 0;
					$log->info("User selected to keep existing port.");
				}
			}
		}
	}
}

########################################
#CheckCrowdConfig                      #
########################################
sub checkCrowdConfig {
	my $application;
	my $mode;
	my $lcApplication;
	my @requiredCrowdConfigItems;
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	$application = $_[0];
	$mode        = $_[1];

	$lcApplication = lc($application);

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_application", $application );
	dumpSingleVarToLog( "$subname" . "_mode",        $mode );

	if ( $globalConfig->param("$lcApplication.crowdIntegration") eq "TRUE" ) {
		if ( $globalConfig->param("general.externalCrowdInstance") eq "FALSE" )
		{
			if ( $globalConfig->param("crowd.enable") eq "TRUE" ) {
				@requiredCrowdConfigItems = ("crowd.installedVersion");

#Iterate through required config items, if any are missing, install cannot continue so return
				if ( checkRequiredConfigItems(@requiredCrowdConfigItems) eq
					"FAIL" )
				{
					$log->warn(
"$subname: $application has been configured for Crowd integration but Crowd does not appear to be installed yet. Cancelling $mode of $application."
					);
					print
"$application has been configured for Crowd integration but Crowd does not appear to be installed yet. Therefore the $application $mode cannot continue, please $mode Crowd and then try again. Press enter to continue. \n\n";
					my $input = <STDIN>;
					return "FAIL";
				}
				else {
					return "SUCCESS";
				}
			}
		}
		else {
			@requiredCrowdConfigItems = (
				"general.externalCrowdHostname",
				"general.externalCrowdPort", "general.ExternalCrowdContext"
			);

#Iterate through required config items, if any are missing install cannot continue and user will have to re-run config generation.
			if ( checkRequiredConfigItems(@requiredCrowdConfigItems) eq "FAIL" )
			{
				$log->warn(
"$subname: $application has been configured for Crowd integration with an external Crowd instance. However external Crowd instance parameters have not been defined in our config. Cancelling $mode of $application."
				);
				print
"$application has been configured for Crowd integration using an external Crowd instance. However we do not appear to have this configuration available in settings.cfg. Please re-run the suite config (option G on the main menu) and then try this $mode again. Press enter to continue. \n\n";
				my $input = <STDIN>;
				exit -1;
				return "FAIL";
			}
			else {
				return "SUCCESS";
			}
		}
	}
}

########################################
#Check for Available Updates           #
########################################
sub checkForAvailableUpdates {
	my $cfg;
	my $configItem;
	my $availCode;
	my $configValue;
	my $application;
	my $lcApplication;
	my $versionCompareResult;
	my @parameterNull;
	my $input;
	my $subname = ( caller(0) )[3];

	#force a reload of the global config file
	loadSuiteConfig();

	#undefine any previous details in the hash in case we are re-running:
	undef(%appsWithUpdates);

	$log->debug("BEGIN: $subname");
	foreach (@suiteApplications) {

		$application   = $_;
		$lcApplication = lc($application);

		@parameterNull =
		  $globalConfig->param("$lcApplication.installedVersion");
		if ( ( $#parameterNull == -1 )
			|| $globalConfig->param("$lcApplication.installedVersion") eq "" )
		{
			$log->debug(
"$subname: $application is not installed therefore not checking for updates."
			);
		}
		else {
			$log->debug(
				"$subname: $application is installed. Checking for updates.");
			$versionCompareResult = compareTwoVersions(
				$globalConfig->param("$lcApplication.installedVersion"),
				$latestVersions{"$application"}->{"version"}
			);
			if ( $versionCompareResult eq "LESS" ) {
				$log->debug(
					"$subname: $application update is available installedVer: "
					  . $globalConfig->param("$lcApplication.installedVersion")
					  . " availableVer: "
					  . $latestVersions{"$application"}->{"version"} );
				$appsWithUpdates{"$application"}{"installedVersion"} =
				  $globalConfig->param("$lcApplication.installedVersion");
				$appsWithUpdates{"$application"}{"availableVersion"} =
				  $latestVersions{"$application"}->{"version"};
			}
			else {
				$log->debug("$subname: $application is up to date.");
			}
		}
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

	$log->debug("BEGIN: $subname");

	@requiredConfigItems = @_;

	foreach (@requiredConfigItems) {

		#$_;
		@parameterNull = $globalConfig->param($_);
		if ( ( $#parameterNull == -1 ) || $globalConfig->param($_) eq "" ) {
			$failureCount++;
		}
	}

	$log->debug("Failure count of required config items: $failureCount");
	if ( $failureCount > 0 ) {
		return "FAIL";
	}
	else {
		return "PASS";
	}
}

########################################
#ChownRecursive                        #
########################################
sub chownRecursive {
	my $directory;
	my $osUser;
	my @uidGid;
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	$osUser    = $_[0];
	$directory = $_[1];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_osUser",    $osUser );
	dumpSingleVarToLog( "$subname" . "_directory", $directory );

	#Get UID and GID for the user
	@uidGid = getUserUidGid($osUser);

	print "Chowning files to correct user. Please wait.\n\n";
	$log->debug("CHOWNING: $directory");

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

	$log->debug("BEGIN: $subname");

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
#clearJIRAPluginCache                  #
########################################
sub clearConfluencePluginCache {
	my @cacheDirs = (
		$globalConfig->param("confluence.dataDir") . "/bundled-plugins",
		$globalConfig->param("confluence.dataDir") . "/plugins-cache",
		$globalConfig->param("confluence.dataDir") . "/plugins-osgi-cache",
		$globalConfig->param("confluence.dataDir") . "/plugins-temp",
		$globalConfig->param("confluence.dataDir") . "/bundled-plugins_language"
	);
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	#remove init.d file
	print "Clearing Confluence Plugin Cache, please wait...\n\n";

	removeDirs(@cacheDirs);

	print "Confluence Plugin Cache has been cleaned.\n\n";
}

########################################
#clearJIRAPluginCache                  #
########################################
sub clearJIRAPluginCache {
	my @cacheDirs = (
		$globalConfig->param("jira.dataDir") . "/plugins/.bundled-plugins",
		$globalConfig->param("jira.dataDir") . "/plugins/.osgi-plugins"
	);
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	#remove init.d file
	print "Clearing JIRA Plugin Cache... please wait...\n\n";

	removeDirs(@cacheDirs);
	print "JIRA Plugin Cache has been cleaned.\n\n";
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
	my $version1Delim;
	my $version2Delim;
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	$version1 = $_[0];
	$version2 = $_[1];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_version1", $version1 );
	dumpSingleVarToLog( "$subname" . "_version2", $version2 );

	if ( $version1 =~ m/.*-.*/ ) {
		@splitVersion1 = split( /-/, $version1 );
	}
	else {

		#assume original delimiter of a period
		@splitVersion1 = split( /\./, $version1 );
	}

	if ( $version2 =~ m/.*-.*/ ) {
		@splitVersion2 = split( /-/, $version2 );
	}
	else {

		#assume original delimiter of a period
		@splitVersion2 = split( /\./, $version2 );
	}

#Iterate through first array and test if the version provided is less than or equal to the second array
	for ( $count = 0 ; $count <= 3 ; $count++ ) {
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
		$log->debug("$subname: Newer version is greater than old version.");
		return "GREATER";
	}
	elsif ( $majorVersionStatus eq "EQUAL" & $midVersionStatus eq "LESS" ) {
		$log->debug("$subname: Newer version is less than old version.");
		return "LESS";
	}
	elsif ( $majorVersionStatus eq "EQUAL" & $midVersionStatus eq "GREATER" ) {
		$log->debug("$subname: Newer version is greater than old version.");
		return "GREATER";
	}
	elsif ( $majorVersionStatus eq "EQUAL" & $midVersionStatus eq "EQUAL" &
		!defined($minVersionStatus) )
	{
		$log->debug("$subname: Newer version is equal to old version.");
		return "EQUAL";
	}
	elsif ( $majorVersionStatus eq "EQUAL" & $midVersionStatus eq "EQUAL" &
		$minVersionStatus eq "LESS" )
	{
		$log->debug("$subname: Newer version is less than old version.");
		return "LESS";
	}
	elsif ( $majorVersionStatus eq "EQUAL" & $midVersionStatus eq "EQUAL" &
		$minVersionStatus eq "GREATER" )
	{
		$log->debug("$subname: Newer version is greater than old version.");
		return "GREATER";
	}
	elsif ( $majorVersionStatus eq "EQUAL" & $midVersionStatus eq "EQUAL" &
		$minVersionStatus eq "EQUAL" )
	{
		$log->debug("$subname: Newer version is equal to old version.");
		return "EQUAL";
	}
	elsif ( $majorVersionStatus eq "EQUAL" & $midVersionStatus eq "EQUAL" &
		$minVersionStatus eq "NEWERNULL" )
	{
		$log->debug("$subname: Newer version is greater than old version.");
		return "GREATER";
	}
	elsif ( $majorVersionStatus eq "EQUAL" & $midVersionStatus eq "EQUAL" &
		$minVersionStatus eq "CURRENTNULL" )
	{
		$log->debug("$subname: Newer version is less than old version.");
		return "LESS";
	}
	elsif ( $majorVersionStatus eq "EQUAL" & $midVersionStatus eq "EQUAL" &
		$minVersionStatus eq "BOTHNULL" )
	{
		$log->debug("$subname: Newer version is equal to old version.");
		return "EQUAL";
	}
}

########################################
#CopyDirectory                         #
########################################
sub copyDirectory {
	my $origDirectory;
	my $newDirectory;
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	$origDirectory = $_[0];
	$newDirectory  = $_[1];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_origDirectory", $origDirectory );
	dumpSingleVarToLog( "$subname" . "_newDirectory",  $newDirectory );

	$log->debug("$subname: Copying $origDirectory to $newDirectory.");

	if ( dircopy( $origDirectory, $newDirectory ) == 0 ) {
		$log->logdie(
"Unable to copy folder $origDirectory to $newDirectory. Unknown error occured: $!.\n\n"
		);
	}
}

########################################
#copyFile                              #
########################################
sub copyFile {
	my $inputFile;
	my $outputFile;
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	$inputFile  = $_[0];
	$outputFile = $_[1];    #can also be a directory

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_inputFile",  $inputFile );
	dumpSingleVarToLog( "$subname" . "_outputFile", $outputFile );

	#Create copy of input file to output file
	$log->debug("$subname: Copying $inputFile to $outputFile");
	copy( $inputFile, $outputFile )
	  or $log->logdie("File copy failed for $inputFile to $outputFile: $!");
	$log->debug("$subname: Input file '$inputFile' copied to $outputFile");
}

########################################
#createAndChownDirectory               #
########################################
sub createAndChownDirectory {
	my $directory;
	my $osUser;
	my @uidGid;
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	$directory = $_[0];
	$osUser    = $_[1];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_directory", $directory );
	dumpSingleVarToLog( "$subname" . "_osUser",    $osUser );

	#Get UID and GID for the user
	@uidGid = getUserUidGid($osUser);

	#Check if the directory exists if so just chown it
	if ( -d $directory ) {
		$log->debug("Directory $directory exists, just chowning.");
		print "Directory exists...\n\n";
		chownRecursive( $osUser, $directory );
	}

#If the directory doesn't exist make the path to the directory (including any missing folders)
	else {
		$log->debug(
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

	$log->debug("BEGIN: $subname");

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
#createOrUpdateLineInFile              #
#This function will add a line to the  #
#beginning of a file directly after the#
#'#!' line                             #
########################################
sub createOrUpdateLineInFile {
	my $inputFile;    #Must Be Absolute Path
	my $newLine;
	my $lineReference;
	my $searchFor;
	my $lineReference2;
	my @data;
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	$inputFile      = $_[0];
	$lineReference  = $_[1];    #the line we are looking for
	$newLine        = $_[2];    #the line we want to add
	$lineReference2 = $_[3];    #the #! line we expect

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_inputFile",      $inputFile );
	dumpSingleVarToLog( "$subname" . "_lineReference",  $lineReference );
	dumpSingleVarToLog( "$subname" . "_newLine",        $newLine );
	dumpSingleVarToLog( "$subname" . "_lineReference2", $lineReference2 );
	open( my $inputFileHandle, '<', $inputFile )
	  or $log->logdie("Unable to open file: $inputFile: $!");

	# read file into an array
	@data = <$inputFileHandle>;

	close($inputFileHandle);

	#Search for reference line
	my ($index1) = grep { $data[$_] =~ /^$lineReference.*/ } 0 .. $#data;

	#If you cant find the first reference try for the second reference
	if ( !defined($index1) ) {
		$log->debug("$subname: First search term $lineReference not found.");
		if ( defined($lineReference2) ) {
			$log->debug("$subname: Trying to search for $lineReference2.");
			my ($index1) =
			  grep { $data[$_] =~ /^$lineReference2.*/ } 0 .. $#data;
			if ( !defined($index1) ) {
				$log->logdie(
"No line containing \"$lineReference2\" found in file $inputFile\n\n"
				);
			}

			#Otherwise add the new line after the found line
			else {
				$log->debug(
					"$subname: Adding '$newLine' after $data[$index1]'.");
				splice( @data, $index1 + 1, 0, $newLine );
			}
		}
		else {
			$log->logdie(
"No line containing \"$lineReference\" found in file $inputFile\n\n"
			);
		}
	}
	else {
		$log->debug("$subname: Replacing '$data[$index1]' with $newLine.");
		$data[$index1] = $newLine . "\n";
	}

	#Write out the updated file
	open( my $outputFileHandle, '>', "$inputFile" )
	  or $log->logdie("Unable to open file: $inputFile: $!");
	print $outputFileHandle @data;
	close $outputFileHandle;

}

########################################
#createOrUpdateLineInXML               #
#                                      #
########################################
sub createOrUpdateLineInXML {
	my $inputFile;    #Must Be Absolute Path
	my $newLine;
	my $lineReference;
	my $searchFor;
	my $lineReference2;
	my @data;
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	$inputFile     = $_[0];
	$lineReference = $_[1];    #the line we are looking for
	$newLine       = $_[2];    #the line we want to add

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_inputFile",     $inputFile );
	dumpSingleVarToLog( "$subname" . "_lineReference", $lineReference );
	dumpSingleVarToLog( "$subname" . "_newLine",       $newLine );
	open( my $inputFileHandle, '<', $inputFile )
	  or $log->logdie("Unable to open file: $inputFile: $!");

	# read file into an array
	@data = <$inputFileHandle>;

	close($inputFileHandle);

	#Search for reference line
	my ($index1) = grep { $data[$_] =~ /^$lineReference.*/ } 0 .. $#data;
	my ($index2) = grep { $data[$_] =~ /^$newLine.*/ } 0 .. $#data;

	#If you cant find the first reference try for the second reference
	if ( !defined($index1) ) {
		$log->debug("$subname: First search term $lineReference not found.");
		$log->logdie(
			"No line containing \"$lineReference\" found in file $inputFile\n\n"
		);
	}
	else {
		if ( !defined($index2) ) {
			$log->debug("$subname: Adding '$newLine' after $data[$index1]'.");
			splice( @data, $index1 + 1, 0, $newLine );
		}
	}

	#Write out the updated file
	open( my $outputFileHandle, '>', "$inputFile" )
	  or $log->logdie("Unable to open file: $inputFile: $!");
	print $outputFileHandle @data;
	close $outputFileHandle;

}

########################################
#CreateOSUser                          #
########################################
sub createOSUser {
	my $osUser;
	my @uidParameterNull;
	my @gidParameterNull;
	my $osUserUID;
	my $osUserGID;
	my $application;
	my $lcApplication;
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	$osUser        = $_[0];
	$application   = $_[1];
	$lcApplication = lc($application);

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_osUser", $osUser );

	if ( !getpwnam($osUser) ) {
		print
"The system account '$osUser' does not exist. Creating the account.\n\n";

#Check the configuration file for forced UIDs and GIDs for the system account
#Note these can not be created via the GUI and must be added to the config file manually
		@uidParameterNull = $globalConfig->param("$lcApplication.osUserUID");
		@gidParameterNull = $globalConfig->param("$lcApplication.osUserGID");

		if ( $#uidParameterNull == -1 ) {
			$log->debug("$subname: No GID specified in config for $osUser.");
			$osUserUID = "";
		}
		else {
			$osUserUID = $globalConfig->param("$lcApplication.osUserUID");
			dumpSingleVarToLog( "$subname" . "_osUserUID", $osUserUID );

		}

		if ( $#gidParameterNull == -1 ) {
			$log->debug("$subname: No UID specified in config for $osUser.");
			$osUserGID = "";
		}
		else {
			$osUserGID = $globalConfig->param("$lcApplication.osUserGID");
			dumpSingleVarToLog( "$subname" . "_osUserGID", $osUserGID );

		}

		#Check if group exists
		system("grep $osUser /etc/group");
		if ( $? != 0 ) {
			$log->debug(
				"$subname: System group $osUser does not exist. Adding.");
			print
"The system group '$osUser' does not yet exist. Creating the group now: \n\n";

			#Group does not exist therefore create
			if ( $osUserGID eq "" ) {

				#No GID has been specified in config, adding with default GID
				system("groupadd $osUser");
				if ( $? == -1 ) {
					$log->logdie(
						"$subname: Could not create system group '$osUser'");
				}
				else {
					$log->debug(
						"$subname: System group '$osUser' created successfully"
					);
				}
			}
			else {

				#GID has been specified in config, adding with specified GID
				system("groupadd -g $osUserGID $osUser");
				if ( $? == -1 ) {
					$log->logdie(
						"$subname: Could not create system group '$osUser'");
				}
				else {
					$log->debug(
						"$subname: System group '$osUser' created successfully"
					);
				}
			}
		}
		else {
			$log->debug("$subname: System group $osUser already exists.");
		}

		if ( $osUserUID eq "" ) {

			#No UID has been specified in config, adding with default UID
			system("useradd $osUser -g $osUser");
			if ( $? == -1 ) {
				$log->logdie(
					"$subname: Could not create system user '$osUser'");
			}
			else {
				$log->debug(
					"$subname: System user '$osUser' created successfully.");
			}
		}
		else {

			#UID has been specified in config, adding with specified UID
			system("useradd -u $osUserUID $osUser -g $osUser");
			if ( $? == -1 ) {
				$log->logdie(
					"$subname: Could not create system user '$osUser'");
			}
			else {
				$log->debug(
					"$subname: System user '$osUser' created successfully.");
			}
		}

		print
"The system account '$osUser' has been created successfully. You must now enter a password for the new '$osUser' system account to be used if you wish to log in to it later: \n\n";
		system("passwd $osUser");
		if ( $? == -1 ) {
			$log->warn("$subname: Password creation failed for $osUser");
			print
"Password creation for '$osUser' has failed, as this is not fatal we will continue, however you will need to create a password manually later: \n\n";
		}
		else {
			$log->debug("$subname: Password created for $osUser successfully.");
		}
	}
	else {
		$log->debug("$subname: System user $osUser already exists.");
	}
}

########################################
#getDirSize - Calculate Directory Size    #
########################################
sub getDirSize {

#code written by docsnider on http://bytes.com/topic/perl/answers/603354-calculate-size-all-files-directory
	my ($dir)  = $_[0];
	my ($size) = 0;
	my ($fd);
	my $subname = ( caller(0) )[3];
	opendir( $fd, $dir )
	  or $log->logdie(
"Unable to open directory to calculate the directory size. Unable to continue: $!"
	  );

	for my $item ( readdir($fd) ) {
		next if ( $item =~ /^\.\.?$/ );

		my ($path) = "$dir/$item";

		$size += (
			( -d $path )
			? getDirSize($path)
			: ( -f $path ? ( stat($path) )[7] : 0 )
		);
	}

	closedir($fd);
	return ($size);
}

########################################
#displayQuickConfig                    #
########################################
sub displayQuickConfig {

	my $subname = ( caller(0) )[3];
	my $menu;

	# define the main menu as a multiline string
	$menu = generateMenuHeader( "MINI", "Quick URL Menu", "" );

	# print the main menu
	print $menu;

	foreach my $application (@suiteApplications) {
		my $lcApplication = lc($application);
		my @parameterNull =
		  $globalConfig->param("$lcApplication.installedVersion");
		my $url;
		if (
			defined( $globalConfig->param("$lcApplication.installedVersion") ) &
			!( $#parameterNull == -1 ) )
		{
			print "      $application Config\n";
			if ( $globalConfig->param("general.apacheProxy") eq "TRUE" ) {
				if ( $globalConfig->param("general.apacheProxySingleDomain") eq
					"TRUE" )
				{
					if ( $globalConfig->param("general.apacheProxySSL") eq
						"TRUE" )
					{
						$url =
						    "https://"
						  . $globalConfig->param("general.apacheProxyHost")
						  . ":"
						  . $globalConfig->param("general.apacheProxyPort")
						  . getConfigItem( "$lcApplication.appContext",
							$globalConfig );
					}
					else {
						$url =
						    "http://"
						  . $globalConfig->param("general.apacheProxyHost")
						  . ":"
						  . $globalConfig->param("general.apacheProxyPort")
						  . getConfigItem( "$lcApplication.appContext",
							$globalConfig );
					}
				}
				else {
					if (
						$globalConfig->param("$lcApplication.apacheProxySSL") eq
						"TRUE" )
					{
						$url =
						  "https://"
						  . $globalConfig->param(
							"$lcApplication.apacheProxyHost")
						  . ":"
						  . $globalConfig->param(
							"$lcApplication.apacheProxyPort")
						  . getConfigItem( "$lcApplication.appContext",
							$globalConfig );
					}
					else {
						$url =
						  "http://"
						  . $globalConfig->param(
							"$lcApplication.apacheProxyHost")
						  . ":"
						  . $globalConfig->param(
							"$lcApplication.apacheProxyPort")
						  . getConfigItem( "$lcApplication.appContext",
							$globalConfig );
					}
				}
			}
			else {
				$url =
				    "http://localhost:"
				  . $globalConfig->param("$lcApplication.connectorPort")
				  . getConfigItem( "$lcApplication.appContext", $globalConfig );
			}

			print "      URL: $url\n\n";
			print "      ----------------------------------------\n\n";
		}
	}

	print "Please press enter to return to the main menu..";
	my $input = <STDIN>;
}

########################################
#Download Atlassian Installer          #
########################################
sub downloadAtlassianInstaller {
	my $type;
	my $application;
	my $lcApplication;
	my $version;
	my $downloadURL;
	my $architecture;
	my $parsedURL;
	my @downloadDetails;
	my $input;
	my $downloadResponseCode;
	my $absoluteFilePath;
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	$type          = $_[0];
	$application   = $_[1];
	$version       = $_[2];
	$architecture  = $_[3];
	$lcApplication = lc($application);

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_type",         $type );
	dumpSingleVarToLog( "$subname" . "_application",  $application );
	dumpSingleVarToLog( "$subname" . "_version",      $version );
	dumpSingleVarToLog( "$subname" . "_architecture", $architecture );

	print "Beginning download of $application, please wait...\n\n";

	#Get the URL for the version we want to download
	if ( $type eq "LATEST" ) {
		$log->debug(
"$subname: Grabbing latest version details for $application from cache"
		);
		@downloadDetails = (
			$latestVersions{"$application"}->{"URL"},
			$latestVersions{"$application"}->{"version"}
		);
	}
	else {
		$log->debug("$subname: Downloading version $version of $application");
		@downloadDetails =
		  getVersionDownloadURL( $lcApplication, $architecture, $version );
	}
	dumpSingleVarToLog( "$subname" . "_downloadDetails[0]",
		$downloadDetails[0] );
	dumpSingleVarToLog( "$subname" . "_downloadDetails[1]",
		$downloadDetails[1] );

	#Check if we are trying to download a supported version
	if ( $enableEAPDownloads != 1 ) {
		if ( isSupportedVersion( $lcApplication, $downloadDetails[1] ) eq "no" )
		{
			$log->warn(
"$subname: Version $version of $application is has not been fully tested with this script."
			);

			$input = getBooleanInput(
"This version of $application ($downloadDetails[1]) has not been fully tested with this script. Do you wish to continue?: [yes]"
			);
			dumpSingleVarToLog( "$subname" . "_input", $input );
			print "\n";
			if ( $input eq "no" ) {
				$log->logdie(
"User opted not to continue as the version is not supported, please try again with a specific version which is supported, or check for an update to this script."
				);
			}
			else {
				$log->warn(
"$subname: User has opted to download $version of $application even though it has not been tested with this script."
				);
			}
		}
	}

	#Parse the URL so that we can get specific sections of it
	$parsedURL = URI->new( $downloadDetails[0] );
	my @bits = $parsedURL->path_segments();

	#Set the download to show progress as we download
	$ua->show_progress(1);

	#Check that the install/download directory exists, if not create it
	print "Checking that root install dir exists...\n\n";
	createDirectory(
		escapeFilePath( $globalConfig->param("general.rootInstallDir") ) );

	$absoluteFilePath =
	  escapeFilePath( $globalConfig->param("general.rootInstallDir") ) . "/"
	  . $bits[ @bits - 1 ];
	dumpSingleVarToLog( "$subname" . "_absoluteFilePath", $absoluteFilePath );

#Check if local file already exists and if it does, provide the option to skip downloading
	if ( -e $absoluteFilePath ) {
		$log->debug(
			"$subname: The install file $absoluteFilePath already exists.");

		$input =
		  getBooleanInput( "The local install file "
			  . $absoluteFilePath
			  . " already exists. Would you like to skip downloading it again?: [yes]"
		  );
		dumpSingleVarToLog( "$subname" . "_input", $input );
		print "\n";
		if ( $input eq "yes" || $input eq "default" ) {
			$log->debug(
"$subname: User opted to skip redownloading the installer file for $application."
			);
			$downloadDetails[2] =
			    escapeFilePath( $globalConfig->param("general.rootInstallDir") )
			  . "/"
			  . $bits[ @bits - 1 ];
			return @downloadDetails;
		}
	}
	$log->debug("$subname: Beginning download.");

	#Download the file and store the HTTP response code
	print "Downloading file from Atlassian...\n\n";
	$downloadResponseCode = getstore( $downloadDetails[0],
		escapeFilePath( $globalConfig->param("general.rootInstallDir") ) . "/"
		  . $bits[ @bits - 1 ] )
	  or $log->logdie(
		"Fatal error while attempting to download $downloadDetails[0]: $?");
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
		  escapeFilePath( $globalConfig->param("general.rootInstallDir") ) . "/"
		  . $bits[ @bits - 1 ];
		return @downloadDetails;
	}
	else {
		$log->logdie(
"Could not download $application version $version. HTTP Response received was: '$downloadResponseCode'"
		);
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

	$log->debug("BEGIN: $subname");

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

		$input =
		  getBooleanInput( "The local download file "
			  . $absoluteFilePath
			  . " already exists. Would you like to skip downloading it again?: [yes]"
		  );
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
			$downloadResponseCode )
		  or $log->logdie(
			"Fatal error while attempting to download $downloadURL: $?");

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

	$log->debug("BEGIN: $subname");

	$dbType = $_[0];
	$cfg    = $_[1];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_dbType", $dbType );

	print
"Not all the Atlassian applications come with the $dbType connector so we need to download it.\n\n";
	if ( $dbType eq "MySQL" ) {
		print
"In a web browser please visit http://dev.mysql.com/downloads/connector/j/ and note down the version number (such as 5.2.22).\n";
		print "Enter the version number displayed on the page above: ";
		while ( $LOOP == 1 ) {
			$input = getGenericInput();
			$log->debug("MYSQL JDBC version number entered: $input");
			if ( $input eq "default" ) {
				$log->debug("MYSQL JDBC null version entered.");
				print
"You did not enter anything, please enter a valid version number: ";
			}
			else {
				$log->debug( "MYSQL JDBC version number entered - $subname"
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
		$log->debug("JDBC download succeeded.");
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
		$log->debug("Extracting $archiveFile.");

		#Extract
		$ae->extract( to => $Bin );
		if ( $ae->error ) {
			$log->logdie(
"Unable to extract $archiveFile. The following error was encountered: $ae->error\n\n"
			);
		}

		print "Extracting $archiveFile has been completed.\n\n";
		$log->debug("Extract completed successfully.");

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
	my $downloadResponseCode;
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	$architecture = $_[0];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_architecture", $architecture );

	#Configure all products in the suite

	#Iterate through each of the products, get the URL and download
	foreach (@suiteApplications) {
		@downloadDetails = getLatestDownloadURL( $_, $architecture );

		$parsedURL = URI->new( $downloadDetails[0] );
		my @bits = $parsedURL->path_segments();
		$ua->show_progress(1);

		$downloadResponseCode = getstore( $downloadDetails[0],
			    escapeFilePath( $globalConfig->param("general.rootInstallDir") )
			  . "/"
			  . $bits[ @bits - 1 ] )
		  or $log->logdie(
			"Fatal error while attempting to download $downloadDetails[0]: $?"
		  );

#Test if the download was a success, if not die and return HTTP response code otherwise return the absolute path to file
		if ( is_success($downloadResponseCode) ) {
			$log->debug(
"$subname: Download completed successfully with HTTP response code $downloadResponseCode."
			);
			print "\n";
			print "Download completed successfully.\n\n";
		}
		else {
			$log->logdie(
"Could not download $_. HTTP Response received was: '$downloadResponseCode'"
			);
		}
	}
}

########################################
#dumpHashToFile                        #
########################################
sub dumpHashToFile {
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	#Code thanks go to Kyle on http://www.perlmonks.org/?node_id=704380

	my ( $fileName, %hash_ref ) = @_;

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_fileName", $fileName );
	dumpSingleVarToLog( "$subname" . "_hash_ref", %hash_ref );

	open( my $outputFileHandle, '>', $fileName )
	  or $log->logdie("Can't write to '$fileName': $!\n\n");
	local $Data::Dumper::Terse = 1;    # no '$VAR1 = '
	local $Data::Dumper::Useqq = 1;    # double quoted strings
	print $outputFileHandle Dumper \%hash_ref;
	close $outputFileHandle or log->logdie("Can't close '$fileName': $!\n\n");

}

########################################
#dumpSingleVarToLog                    #
########################################
sub dumpSingleVarToLog {

	my $varName  = $_[0];
	my $varValue = $_[1];
	if ( $log->is_debug() ) {
		$log->debug("VARDUMP: $varName: $varValue");
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
#Escape Filepath                       #
########################################
sub escapeFilePath {
	my $pathIn;

	$pathIn = $_[0];
	$pathIn =~ s/[ ]/\\$&/g;

	return $pathIn;
}

########################################
#extractAndMoveFile                #
########################################
sub extractAndMoveFile {
	my $inputFile;
	my $expectedFolderName;    #MustBeAbsolute
	my $date = strftime "%Y%m%d_%H%M%S", localtime;
	my $osUser;
	my @uidGid;
	my $upgrade;
	my $mode;
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

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
	createDirectory(
		escapeFilePath( $globalConfig->param("general.rootInstallDir") ) );

	#Make sure file exists
	if ( !-e $inputFile ) {
		$log->logdie(
			"File $inputFile could not be extracted. File does not exist.\n\n"
		);
	}

	#Set up extract object
	my $ae = Archive::Extract->new( archive => $inputFile );

	print "Extracting $inputFile. Please wait...\n\n";
	$log->debug("$subname: Extracting $inputFile");

	#Extract
	$ae->extract(
		to => escapeFilePath( $globalConfig->param("general.rootInstallDir") )
	);
	if ( $ae->error ) {
		$log->logdie(
"Unable to extract $inputFile. The following error was encountered: $ae->error\n\n"
		);
	}

	print "Extracting $inputFile has been completed.\n\n";
	$log->debug("$subname: Extract completed.");

	#Check for existing folder and provide option to backup
	if ( -d $expectedFolderName ) {
		if ( $mode eq "UPGRADE" ) {
			print "Deleting old install directory please wait...\n\n";
			rmtree( ["$expectedFolderName"] );

			$log->debug(
				"$subname: Moving $ae->extract_path() to $expectedFolderName");
			moveDirectory( $ae->extract_path(), $expectedFolderName );
			$log->debug("$subname: Chowning $expectedFolderName to $osUser");
			chownRecursive( $osUser, $expectedFolderName );
		}
		else {
			my $LOOP = 1;
			my $input;
			$log->debug("$subname: $expectedFolderName already exists.");
			print "The destination directory '"
			  . $expectedFolderName
			  . " already exists. Would you like to overwrite or move to a backup? o=overwrite\\b=backup [b]\n";
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
					$log->debug("$subname: User opted to backup directory");
					$LOOP = 0;
					moveDirectory( $expectedFolderName,
						$expectedFolderName . $date );
					print "Folder backed up to "
					  . $expectedFolderName
					  . $date . "\n\n";
					$log->debug( "$subname: Folder backed up to "
						  . $expectedFolderName
						  . $date );

					$log->debug(
"$subname: Moving $ae->extract_path() to $expectedFolderName"
					);
					moveDirectory( $ae->extract_path(), $expectedFolderName );

					$log->debug(
						"$subname: Chowning $expectedFolderName to $osUser");
					chownRecursive( $osUser, $expectedFolderName );
				}

#If user selects, overwrite existing folder by deleting and then moving new directory in place
				elsif (( lc $input ) eq "overwrite"
					|| ( lc $input ) eq "o" )
				{
					$log->debug("$subname: User opted to overwrite directory");
					$LOOP = 0;

#Considered failure handling for rmtree however based on http://perldoc.perl.org/File/Path.html used
#recommended in built error handling.
					rmtree( ["$expectedFolderName"] );

					$log->debug(
"$subname: Moving $ae->extract_path() to $expectedFolderName"
					);
					moveDirectory( $ae->extract_path(), $expectedFolderName );
					$log->debug(
						"$subname: Chowning $expectedFolderName to $osUser");
					chownRecursive( $osUser, $expectedFolderName );
				}

				#Input was not recognised, ask user for input again
				else {
					$log->debug(
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
		$log->debug(
			"$subname: Moving $ae->extract_path() to $expectedFolderName");
		moveDirectory( $ae->extract_path(), $expectedFolderName );
		$log->debug("$subname: Chowning $expectedFolderName to $osUser");
		chownRecursive( $osUser, $expectedFolderName );
	}
}

########################################
#findDistro                            #
########################################
sub findDistro {
	my $distribution;
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

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

	$log->debug("BEGIN: $subname");

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
		generateStashConfig( $mode, $cfg );
	}
	elsif ( $lcApplication eq "bamboo" ) {
		generateBambooConfig( $mode, $cfg );
	}

	$log->info("Writing out config file to disk.");
	$cfg->write($configFile);
	loadSuiteConfig();
}

########################################
#Generate Available Updates String     #
########################################
sub generateAvailableUpdatesString {
	my $returnString;
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");
	$returnString =
"      There are updates available for one or more of your installed applications:\n";

	foreach my $key ( keys %appsWithUpdates ) {

		$returnString .=
"      $key: $appsWithUpdates{$key}->{installedVersion} --> $appsWithUpdates{$key}->{availableVersion}\n";

	}
	$availableUpdatesString = $returnString;
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
	my @initGeneric;
	my @initSpecific;
	my $grep1stParam;
	my $grep2ndParam;
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	$application  = $_[0];
	$runUser      = $_[1];
	$baseDir      = $_[2];
	$startCmd     = $_[3];
	$stopCmd      = $_[4];
	$grep1stParam = $_[5];
	$grep2ndParam = $_[6];

	$lcApplication = lc($application);

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_application", $application );
	dumpSingleVarToLog( "$subname" . "_runUser",     $runUser );
	dumpSingleVarToLog( "$subname" . "_baseDir",     $baseDir );
	dumpSingleVarToLog( "$subname" . "_startCmd",    $startCmd );
	dumpSingleVarToLog( "$subname" . "_stopCmd",     $stopCmd );

	if ( $distro eq "redhat" ) {
		@initSpecific = (
			"#!/bin/sh -e\n",
			"#" . $application . " startup script\n",
			"#chkconfig: 2345 80 05\n",
			"#description: " . $application . "\n"
		);
	}
	elsif ( $distro eq "debian" ) {
		@initSpecific = (
			"#!/bin/sh -e\n",
			"### BEGIN INIT INFO\n",
			"# Provides:          $application\n",
			"# Required-Start:    \n",
			"# Required-Stop:     \n",
			"# Default-Start:     2 3 4 5\n",
			"# Default-Stop:      0 1 6\n",
			"# Short-Description: Start $lcApplication at boot time\n",
			"# Description:       Enable auto startup of $lcApplication.\n",
			"### END INIT INFO\n"
		);
	}

	@initGeneric = (
		"\n",
		"APP=" . $application . "\n",
		"LCAPP=" . $lcApplication . "\n",
		"USER=" . $runUser . "\n",
		"BASE=" . $baseDir . "\n",
		"STARTCOMMAND=\"" . $startCmd . "\"\n",
		"STOPCOMMAND=\"" . $stopCmd . "\"\n",
		"GREP1STPARAM=\"" . $grep1stParam . "\"\n",
		"GREP2NDPARAM=\"" . $grep2ndParam . "\"\n",
		"\n",
		'for var in "$@"' . "\n",
		'do' . "\n",
		'  if [[ $var == "--disable-kill"  ]]; then' . "\n",
		'    DISABLEKILL="TRUE"' . "\n",
		'  else' . "\n",
		'    DISABLEKILL="FALSE"' . "\n",
		'  fi' . "\n",
		'done' . "\n",
		"\n",
		'case "$1" in' . "\n",
		"  # Start command\n",
		"  start)\n",
		'    echo "Starting $APP"' . "\n",
		'    /bin/su -m $USER -c "$BASE/$STARTCOMMAND &> /dev/null"' . "\n",
		'    echo "$APP started successfully"' . "\n",
		"    ;;\n",
		"  # Stop command\n",
		"  stop)\n",
		'    echo "Stopping $APP"' . "\n",
		'    /bin/su -m $USER -c "$BASE/$STOPCOMMAND &> /dev/null"' . "\n",
		'    if [[ $DISABLEKILL != "TRUE"  ]]; then' . "\n",
'      echo "Sleeping for 20 seconds to ensure $APP has successfully stopped"'
		  . "\n",
		'      sleep 20' . "\n",
		"\n",
'      PIDS=`ps -ef | grep $GREP1STPARAM | grep $GREP2NDPARAM | grep -v \'ps -ef | grep\' | awk \'{print $2}\'`'
		  . "\n",
		"\n",
		'      if [[ $PIDS == ""  ]]; then' . "\n",
		'        echo "$APP stopped successfully"' . "\n",
		'      else' . "\n",
		'        echo "$APP still running... Killing the process..."' . "\n",
		'        kill -9 $PIDS' . "\n",
		'        echo "$APP killed successfully"' . "\n",
		'      fi' . "\n",
		'    else' . "\n",
		'      echo "$APP stopped successfully"' . "\n",
		'    fi' . "\n",
		"\n",
		"    ;;\n",
		"   # Restart command\n",
		"   restart)\n",
		'        $0 stop' . "\n",
		"        sleep 5\n",
		'        $0 start' . "\n",
		"        ;;\n",
		"  *)\n",
		'    echo "Usage: /etc/init.d/$LCAPP {start|restart|stop}"' . "\n",
		"    exit 1\n",
		"    ;;\n",
		"esac\n",
		"\n",
		"exit 0\n"
	);

	push( @initSpecific, @initGeneric );

	#Write out file to /etc/init.d
	$log->debug("$subname: Writing out init.d file for $application.");
	open( my $outputFileHandle, '>', "/etc/init.d/$lcApplication" )
	  or $log->logdie("Unable to open file /etc/init.d/$lcApplication: $!");
	print $outputFileHandle @initSpecific;
	close $outputFileHandle;

	#Make the new init.d file executable
	$log->debug("$subname: Chmodding init.d file for $lcApplication.");
	chmod 0755, "/etc/init.d/$lcApplication"
	  or $log->logdie("Couldn't chmod /etc/init.d/$lcApplication: $!");

	#Always call an update to the main Atlassian init.d script
	generateInitDforSuite();
}

########################################
#GenerateInitDForSuite                 #
########################################
sub generateInitDforSuite {
	my @initGeneric;
	my @addToInitGeneric;
	my @initSpecific;
	my @stopCommands;
	my @startCommands;
	my @addToCommands;
	my @enabledApps;

	my $subname = ( caller(0) )[3];
	my $isBambooInstalled;
	my $isCrowdInstalled;
	my $isConfluenceInstalled;
	my $isFisheyeInstalled;
	my $isJiraInstalled;
	my $isStashInstalled;
	my @parameterNull;
	my $lcApplication;
	my $application;
	my $input;

	$log->debug("BEGIN: $subname");

	#Get current suite install status
	@parameterNull = $globalConfig->param("bamboo.installedVersion");
	if ( ( $#parameterNull == -1 )
		|| $globalConfig->param("bamboo.installedVersion") eq "" )
	{
		$isBambooInstalled = "FALSE";
	}
	else {
		$isBambooInstalled = "TRUE";
		push( @enabledApps, "Bamboo" );
	}

	@parameterNull = $globalConfig->param("confluence.installedVersion");
	if ( ( $#parameterNull == -1 )
		|| $globalConfig->param("confluence.installedVersion") eq "" )
	{
		$isConfluenceInstalled = "FALSE";
	}
	else {
		$isConfluenceInstalled = "TRUE";
		push( @enabledApps, "Confluence" );
	}

	@parameterNull = $globalConfig->param("crowd.installedVersion");
	if ( ( $#parameterNull == -1 )
		|| $globalConfig->param("crowd.installedVersion") eq "" )
	{
		$isCrowdInstalled = "FALSE";
	}
	else {
		$isCrowdInstalled = "TRUE";
		push( @enabledApps, "Crowd" );
	}

	@parameterNull = $globalConfig->param("fisheye.installedVersion");
	if ( ( $#parameterNull == -1 )
		|| $globalConfig->param("fisheye.installedVersion") eq "" )
	{
		$isFisheyeInstalled = "FALSE";
	}
	else {
		$isFisheyeInstalled = "TRUE";
		push( @enabledApps, "Fisheye" );
	}

	@parameterNull = $globalConfig->param("jira.installedVersion");
	if ( ( $#parameterNull == -1 )
		|| $globalConfig->param("jira.installedVersion") eq "" )
	{
		$isJiraInstalled = "FALSE";
	}
	else {
		$isJiraInstalled = "TRUE";
		push( @enabledApps, "JIRA" );
	}

	@parameterNull = $globalConfig->param("stash.installedVersion");
	if ( ( $#parameterNull == -1 )
		|| $globalConfig->param("stash.installedVersion") eq "" )
	{
		$isStashInstalled = "FALSE";
	}
	else {
		$isStashInstalled = "TRUE";
		push( @enabledApps, "Stash" );
	}

	if ( $distro eq "redhat" ) {
		@initSpecific = (
			"#!/bin/sh -e\n",
			"# Atlassian Suite startup script\n",
			, "#description: Atlassian stop/start/restart script. \n"
		);
	}
	elsif ( $distro eq "debian" ) {
		@initSpecific = (
			"#!/bin/sh -e\n",
			"### BEGIN INIT INFO\n",
			"# Provides:          Atlassian Suite\n",
			"# Required-Start:    \n",
			"# Required-Stop:     \n",
"# Short-Description: Control all installed Atlassian Suite apps with one command.\n",
"# Description:       Control all installed Atlassian Suite apps with one command.\n",
			"### END INIT INFO\n"
		);
	}

	foreach (@enabledApps) {
		undef(@addToCommands);
		$application   = $_;
		$lcApplication = lc($application);

		@addToCommands = (
			"    echo \"Stopping $application\"\n",
"    if (service $lcApplication stop --disable-kill > /dev/null 2>\&1) ; then\n",
			"        echo \"$application Stopped Successfully\"\n",
			"    else\n",
			"            APP_PID=`ps -ef | grep "
			  . $globalConfig->param("$lcApplication.processSearchParameter1")
			  . " | grep "
			  . $globalConfig->param("$lcApplication.processSearchParameter2")
			  . "| grep -v \'ps -ef | grep\' | awk \'{print \$2}\'`\n",
			'        if (`ps -ef | grep -i '
			  . $lcApplication
			  . ' | grep -v "grep"` && $APP_PID != "") ; then' . "\n",
"            echo 'Unable to stop $application gracefully therefore killing it'\n",
			'            kill -9 $APP_PID' . "\n",
			"            else\n",
"                echo '$application does not appear to be running'\n",
			"            echo \n",
			"        fi\n",
			"    fi\n",
		);

		push( @stopCommands, @addToCommands );
		undef(@addToCommands);
		@addToCommands = (
			"    if service $lcApplication start > /dev/null 2>\&1; then\n",
			"        echo $application Started Successfully\n",
			"    else\n",
"        echo 'Unable to start $application automagically. Please try to start it up manually'\n\n",
			"    fi\n",
		);

		push( @startCommands, @addToCommands );
		undef(@addToCommands);
	}

	@initGeneric = (
		"\n",
		'case "$1" in' . "\n",
		"  # Start command\n",
		"  start)\n", '    echo "Starting the Atlassian Suite"' . "\n"
	);
	push( @initGeneric, @startCommands );
	@addToInitGeneric = (
		'    echo "Atlassian Suite Started Successfully"' . "\n",
		"    ;;\n",
		"  # Stop command\n",
		"  stop)\n",
		'    echo "Stopping the Atlassian Suite"' . "\n"
	);
	push( @initGeneric, @addToInitGeneric );
	push( @initGeneric, @stopCommands );
	undef(@addToInitGeneric);
	@addToInitGeneric = (
		'    echo "Atlassian Suite stopped successfully"' . "\n",
		"    ;;\n",
		"   # Restart command\n",
		"   restart)\n",
		'    echo "Restarting Atlassian Suite"' . "\n"
	);
	push( @initGeneric, @addToInitGeneric );
	push( @initGeneric, @stopCommands );
	undef(@addToInitGeneric);
	@addToInitGeneric = (
'    echo "Sleeping for 20 seconds to allow services to stop gracefully"'
		  . "\n",
		"        sleep 20\n"
	);
	push( @initGeneric, @addToInitGeneric );
	push( @initGeneric, @startCommands );
	undef(@addToInitGeneric);
	@addToInitGeneric = (
		'    echo "Atlassian Suite restarted successfully"' . "\n",
		"        ;;\n",
		"  *)\n",
		'    echo "Usage: /etc/init.d/atlassian {start|restart|stop}"' . "\n",
		"    exit 1\n",
		"    ;;\n",
		"esac\n",
		"\n",
		"exit 0\n"
	);

	push( @initGeneric,  @addToInitGeneric );
	push( @initSpecific, @initGeneric );

	#Write out file to /etc/init.d
	$log->debug("$subname: Writing out init.d file for atlassian.");
	open( my $outputFileHandle, '>', "/etc/init.d/atlassian" )
	  or $log->logdie("Unable to open file /etc/init.d/atlassian: $!");
	print $outputFileHandle @initSpecific;
	close $outputFileHandle;

	#Make the new init.d file executable
	$log->debug("$subname: Chmodding init.d file for atlassian.");
	chmod 0755, "/etc/init.d/atlassian"
	  or $log->logdie("Couldn't chmod /etc/init.d/atlassian: $!");
}

########################################
#Generate Menu Header                  #
########################################
sub generateMenuHeader {
	my $menuHead;
	my $menuFooter;
	my $menuTitle;
	my $defaultMenuBodyText;
	my $inputTitle;
	my $expandedTitle;
	my $mode;
	my $inputBodyText;
	my $titleLength;
	my $fullMenu;
	my $subname = ( caller(0) )[3];

	$mode          = $_[0];    #FULL/MINI
	$inputTitle    = $_[1];    #TITLE
	$inputBodyText = $_[2];    #Body text to replace default body text

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_mode",          $mode );
	dumpSingleVarToLog( "$subname" . "_inputTitle",    $inputTitle );
	dumpSingleVarToLog( "$subname" . "_inputBodyText", $inputBodyText );

	$log->debug("BEGIN: $subname");

	#MenuHead will always display as will MenuFooter and MenuTitle
	#MenuBodyText is optional and will display based on input to this function
	$menuHead = <<'END_HEAD';

      Welcome to the ASM Script for Atlassian(R)

      Copyright (C) 2012-2014  Stuart Ryan
      
END_HEAD

	$defaultMenuBodyText = <<'END_BODY';
      ###########################################################################################
      I would like to thank Atlassian for providing me with complimentary OpenSource licenses to
      CROWD, JIRA, Fisheye, Confluence, Greenhopper and Team Calendars for Confluence.
    
      I would also like to say a massive thank you to Turnkey Internet (www.turnkeyinternet.net)
      for sponsoring me with free hosting without which I would not have been able to write, 
      and continue hosting the Atlassian Suite for my open source projects including this script.
      ###########################################################################################

END_BODY

	$menuFooter = <<'END_FOOTER';
      This program comes with ABSOLUTELY NO WARRANTY;
      This is free software, and you are welcome to redistribute it
      under certain conditions; read the COPYING file included for details.
      
END_FOOTER

	$expandedTitle = "* " . $inputTitle . " *";

	$titleLength = length($expandedTitle);

	$menuTitle =
	    "      "
	  . "*" x $titleLength . "\n"
	  . "      "
	  . $expandedTitle . "\n"
	  . "      "
	  . "*" x $titleLength . "\n\n";

	if ( $inputBodyText eq "" && $mode eq "FULL" ) {
		$fullMenu = $menuHead . $defaultMenuBodyText . $menuFooter . $menuTitle;
	}
	elsif ( $inputBodyText eq "" && $mode eq "MINI" ) {
		$fullMenu = $menuHead . $menuFooter . $menuTitle;
	}
	elsif ( $inputBodyText ne "" && $mode eq "FULL" ) {
		$fullMenu = $menuHead . $inputBodyText . $menuFooter . $menuTitle;
	}
	elsif ( $inputBodyText ne "" && $mode eq "MINI" ) {
		$fullMenu = $menuHead . $inputBodyText . $menuFooter . $menuTitle;
	}
	else {
		$fullMenu = $menuHead . $defaultMenuBodyText . $menuFooter . $menuTitle;
	}
	return $fullMenu;
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

	$log->debug("BEGIN: $subname");

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
			elsif ( $cfg->param($configParam) eq "" ) {
				$defaultValue = $defaultInputValue;
				$log->debug(
"$subname: Current parameter $configParam is NULL, returning '$defaultInputValue'"
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

		#if we are not in update mode we expect this to be null
		$log->debug(
"$subname: Current parameter $configParam is undefined, returning '$defaultInputValue'"
		);
		$defaultValue = $defaultInputValue;
	}

	$input = getBooleanInput( $messageText . " [" . $defaultValue . "]: " );
	print "\n";

#If default option is selected (i.e. just a return), use default value, set to boolean value based on return
	if ( $input eq "yes"
		|| ( $input eq "default" && $defaultValue eq "yes" ) )
	{
		$log->debug(
			"$subname: Input entered was 'yes' setting $configParam to 'TRUE'"
		);
		$cfg->param( $configParam, "TRUE" );
	}
	elsif ( $input eq "no"
		|| ( $input eq "default" && $defaultValue eq "no" ) )
	{
		$log->debug(
			"$subname: Input entered was 'no' setting $configParam to 'FALSE'"
		);
		$cfg->param( $configParam, "FALSE" );
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
	my $validationRegex;
	my $validationFailureMessage;
	my $LOOP    = 1;
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	$mode                     = $_[0];
	$cfg                      = $_[1];
	$configParam              = $_[2];
	$messageText              = $_[3];
	$defaultInputValue        = $_[4];
	$validationRegex          = $_[5];
	$validationFailureMessage = $_[6];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_mode",              $mode );
	dumpSingleVarToLog( "$subname" . "_configParam",       $configParam );
	dumpSingleVarToLog( "$subname" . "_messageText",       $messageText );
	dumpSingleVarToLog( "$subname" . "_defaultInputValue", $defaultInputValue );
	dumpSingleVarToLog( "$subname" . "_validationRegex",   $validationRegex );
	dumpSingleVarToLog( "$subname" . "_validationFailureRegex",
		$validationFailureMessage );

	#Check if the parameter is null (undefined)
	@parameterNull = $cfg->param($configParam);

#Check if we are updating (get current value), or doing a fresh run (use default passed to this function)
	if ( $mode eq "UPDATE" ) {

		#Check if the current value is defined
		if ( defined( $cfg->param($configParam) )
			&& !( $#parameterNull == -1 ) )
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

	while ( $LOOP == 1 ) {
		print $messageText . " [" . $defaultValue . "]: ";
		$input = getGenericInput();
		print "\n";

#If default option is selected (i.e. just a return), use default value, otherwise use input
		if ( $input eq "default" ) {
			$cfg->param( $configParam, $defaultValue );
			$log->debug(
"$subname: default selected, setting $configParam to $defaultValue"
			);
			$LOOP = 0;    #accept input
		}
		elsif ( lc($input) eq "null" ) {
			$cfg->param( $configParam, "NULL" );
			$log->debug("$subname: NULL input, setting $configParam to 'NULL'");
			$LOOP = 0;    #accept input
		}
		else {
			if ( $validationRegex ne "" ) {
				if ( lc($input) =~ $validationRegex ) {
					$cfg->param( $configParam, $input );
					$log->debug("$subname: Setting $configParam to '$input'");
					$LOOP = 0;    #accept input
				}
				else {
					$log->info(
"$subname: The input '$input' did not match the regex '$validationRegex'. Getting input again."
					);
					print $validationFailureMessage;
				}
			}
			else {                #no regex checking needed
				$cfg->param( $configParam, $input );
				$log->debug("$subname: Setting $configParam to '$input'");
				$LOOP = 0;        #accept input
			}
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

	$log->debug("BEGIN: $subname");

	#Check if we have a valid config file already, if so we are updating it
	if ($globalConfig) {
		$log->debug(
"$subname: globalConfig is defined therefore we are performing an update."
		);
		$mode      = "UPDATE";
		$cfg       = $globalConfig;
		$oldConfig = new Config::Simple($configFile);
	}

	#Otherwise we are creating a new file
	else {
		$log->debug(
"$subname: globalConfig is undefined therefore we are creating a new config file from scratch."
		);
		$mode = "NEW";
		$cfg = new Config::Simple( syntax => 'ini' );
	}

	#Generate Main Suite Configuration
	print
"This will guide you through the generation of the config required for the management of the Atlassian suite.\n\n";

	#Get root installation directory
	genConfigItem(
		$mode,
		$cfg,
		"general.rootInstallDir",
		"Please enter the root directory the suite will be installed into.",
		"/opt/atlassian",
		'(?!^.*/$)^(/.*)',
"The input you entered was not in the valid format of '/folder'. Please ensure you enter the absolute path with a "
		  . "leading '/' and NO trailing '/'.\n\n"
	);

	#Get root data directory
	genConfigItem(
		$mode,
		$cfg,
		"general.rootDataDir",
"Please enter the root directory the suite data/home directories will be stored.",
		"/var/atlassian/application-data",
		'(?!^.*/$)^(/.*)',
"The input you entered was not in the valid format of '/folder'. Please ensure you enter the absolute path with a "
		  . "leading '/' and NO trailing '/'.\n\n"
	);

	#Get Proxy configuration
	genBooleanConfigItem( $mode, $cfg, "general.apacheProxy",
		"Will you be using Apache as a front end (i.e. proxy) to the suite ",
		"yes" );

	if ( $cfg->param("general.apacheProxy") eq "TRUE" ) {

		genBooleanConfigItem(
			$mode,
			$cfg,
			"general.apacheProxySingleDomain",
"Will you be using a single domain for ALL suite applications AND will you be using the same HTTP/HTTPS scheme for all applications managed by this script (i.e. all over HTTP OR all over HTTPS not mixed)",
			"yes"
		);

		if ( $cfg->param("general.apacheProxySingleDomain") eq "TRUE" ) {
			genConfigItem(
				$mode,
				$cfg,
				"general.apacheProxyHost",
"Please enter the base URL that will be serving the site (i.e. the proxyName such as yourdomain.com).",
				"",
				$hostnameRegex,
"The input you entered was not in the valid format of 'yourdomain.com' or 'subdomain.yourdomain.com'. Please try again.\n\n"
			);

			genBooleanConfigItem( $mode, $cfg, "general.apacheProxySSL",
				"Will you be running the applications(s) over SSL.", "no" );

			genConfigItem(
				$mode,
				$cfg,
				"general.apacheProxyPort",
"Please enter the port number that apache will serve on (80 for HTTP, 443 for HTTPS in standard situations).",
				"80",
				'^([0-9]*)$',
"The input you entered was not a valid port number, please try again.\n\n"
			);
		}
	}

	#Should backups be compressed
	genBooleanConfigItem(
		$mode,
		$cfg,
		"general.compressBackups",
"Do you wish compress backups (note this will take a lot longer to complete post upgrade tasks)? yes/no ",
		"no"
	);

	#Get Crowd configuration
	genBooleanConfigItem( $mode, $cfg, "crowd.enable",
		"Do you wish to install/manage Crowd? yes/no ", "yes" );

	if ( $cfg->param("crowd.enable") eq "TRUE" ) {

		$input = getBooleanInput(
			"Do you wish to set up/update the Crowd configuration now? [no]: "
		);

		if ( $input eq "yes" ) {
			print "\n";
			generateCrowdConfig( $mode, $cfg );
		}
		$cfg->param( "general.externalCrowdInstance", "FALSE" );
	}
	else {
		genBooleanConfigItem(
			$mode,
			$cfg,
			"general.externalCrowdInstance",
"Will you be using an external Crowd instance (i.e. not installed on this host) for Authentication/SSO? yes/no ",
			"yes"
		);
		if ( $cfg->param("general.externalCrowdInstance") eq "TRUE" ) {

			genConfigItem(
				$mode,
				$cfg,
				"general.externalCrowdHostname",
"Please enter the hostname that the external Crowd instance runs on. (eg crowd.yourdomain.com)",
				"",
				$hostnameRegex,
"The input you entered was not in the valid format of yourdomain.com or subdomain.yourdomain.com, please try again.\n\n"
			);

			genConfigItem(
				$mode,
				$cfg,
				"general.externalCrowdPort",
"Please enter the port that the external Crowd instance runs on. (eg 80/443/8095)",
				"8095",
				'^([0-9]*)$',
"The input you entered was not in a valid numerical format, please try again.\n\n"
			);

			genConfigItem(
				$mode,
				$cfg,
				"general.externalCrowdContext",
"Enter the context that the external Crowd instance should runs under (i.e. /crowd or /login). Write NULL to blank out the context.",
				"/crowd",
				'(?!^.*/$)^(/.*)',
"The input you entered was not in the valid format of '/folder'. Please ensure you enter the path with a "
				  . "leading '/' and NO trailing '/'.\n\n"
			);

		}
	}

	#Get Bamboo configuration
	genBooleanConfigItem( $mode, $cfg, "bamboo.enable",
		"Do you wish to install/manage Bamboo? yes/no ", "yes" );

	if ( $cfg->param("bamboo.enable") eq "TRUE" ) {

		$input = getBooleanInput(
			"Do you wish to set up/update the Bamboo configuration now? [no]: "
		);

		if ( $input eq "yes" ) {
			print "\n";
			generateBambooConfig( $mode, $cfg );
		}
	}

	#Get Confluence configuration
	genBooleanConfigItem( $mode, $cfg, "confluence.enable",
		"Do you wish to install/manage Confluence? yes/no ", "yes" );

	if ( $cfg->param("confluence.enable") eq "TRUE" ) {

		$input = getBooleanInput(
"Do you wish to set up/update the Confluence configuration now? [no]: "
		);

		if ( $input eq "yes" ) {
			print "\n";
			generateConfluenceConfig( $mode, $cfg );
		}
	}

	#Get Fisheye configuration
	genBooleanConfigItem( $mode, $cfg, "fisheye.enable",
		"Do you wish to install/manage Fisheye? yes/no ", "yes" );

	if ( $cfg->param("fisheye.enable") eq "TRUE" ) {

		$input = getBooleanInput(
			"Do you wish to set up/update the Fisheye configuration now? [no]: "
		);

		if ( $input eq "yes" ) {
			print "\n";
			generateFisheyeConfig( $mode, $cfg );
		}
	}

	#Get Jira configuration
	genBooleanConfigItem( $mode, $cfg, "jira.enable",
		"Do you wish to install/manage Jira? yes/no ", "yes" );

	if ( $cfg->param("jira.enable") eq "TRUE" ) {

		$input = getBooleanInput(
			"Do you wish to set up/update the JIRA configuration now? [no]: ");

		if ( $input eq "yes" ) {
			print "\n";
			generateJiraConfig( $mode, $cfg );
		}
	}

	#Get Stash configuration
	genBooleanConfigItem( $mode, $cfg, "stash.enable",
		"Do you wish to install/manage Stash? yes/no ", "yes" );

	if ( $cfg->param("stash.enable") eq "TRUE" ) {
		$input = getBooleanInput(
			"Do you wish to set up/update the Stash configuration now? [no]: "
		);

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
			$log->debug("$subname: Database arch selected is MySQL");
			$LOOP = 0;
			$cfg->param( "general.targetDBType", "MySQL" );
		}
		elsif (( lc $input ) eq "2"
			|| ( lc $input ) eq "postgresql"
			|| ( lc $input ) eq "postgres"
			|| ( lc $input ) eq "postgre" )
		{
			$log->debug("$subname: Database arch selected is PostgreSQL");
			$LOOP = 0;
			$cfg->param( "general.targetDBType", "PostgreSQL" );
		}
		elsif (( lc $input ) eq "3"
			|| ( lc $input ) eq "oracle" )
		{
			$log->debug("$subname: Database arch selected is Oracle");
			$LOOP = 0;
			$cfg->param( "general.targetDBType", "Oracle" );
			print
"You have selected to use the Oracle database. Some of the Atlassian products no longer include the JDBC driver due to licensing. If you would like to automagically copy the JDBC driver over please download it manually and update the settings.cfg file to add general.dbJDBCJar=/path/to/ojdbc6.jar under the general config section. Please press enter to continue...\n";
			$input = <STDIN>;
		}
		elsif (( lc $input ) eq "4"
			|| ( lc $input ) eq "microsoft sql server"
			|| ( lc $input ) eq "mssql" )
		{
			$log->debug("$subname: Database arch selected is MSSQL");
			$LOOP = 0;
			$cfg->param( "general.targetDBType", "MSSQL" );
		}
		elsif (( lc $input ) eq "5"
			|| ( lc $input ) eq "hsqldb"
			|| ( lc $input ) eq "hsql" )
		{
			$log->debug("$subname: Database arch selected is HSQLDB");
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
			$log->debug(
"$subname: User just pressed return therefore existing datbase selection will be kept."
			);

			#keepExistingValueWithNoChange
			$LOOP = 0;
		}
		else {
			$log->debug(
"$subname: User did not enter valid input for database selection. Asking for input again."
			);
			print "Your input '" . $input
			  . "'was not recognised. Please try again and enter either 1, 2, 3, 4 or 5. \n\n";
		}
	}

	if ( defined($oldConfig) ) {
		@parameterNull = $oldConfig->param("general.targetDBType");
	}
	else {
		@parameterNull = -1;
	}

	if ( defined($oldConfig) && !( $#parameterNull == -1 ) ) {
		if ( $cfg->param("general.targetDBType") ne
			$oldConfig->param("general.targetDBType") )
		{
			$log->debug(
"$subname: Database selection has changed from previous config. Nulling out JDBC config option to ensure it gets set correctly if needed."
			);

#Database selection has changed therefore NULL the dbJDBCJar config option to ensure it gets a new value appropriate to the new DB
			$cfg->param( "general.dbJDBCJar", "" );
		}
	}
	@parameterNull = $cfg->param("general.dbJDBCJar");

	if ( $cfg->param("general.targetDBType") eq "MySQL" &
		( ( $#parameterNull == -1 ) || $cfg->param("general.dbJDBCJar") eq "" )
	  )
	{
		$log->debug(
"$subname: MySQL has been selected and no valid JDBC entry defined in config. Download MySQL JDBC driver."
		);
		downloadJDBCConnector( "MySQL", $cfg );
	}

	#Write config and reload
	$log->info("Writing out config file to disk.");
	$cfg->write($configFile);
	loadSuiteConfig();
	$globalArch = whichApplicationArchitecture();

	print
"The suite configuration has been generated successfully. Please press enter to return to the main menu.";
	$input = <STDIN>;
}

########################################
#Get all the latest download URLs      #
########################################
sub getAllLatestDownloadURLs {
	my @returnArray;
	my @downloadArray;
	my $application;
	my $decoded_json;
	my $lcApplication;
	my $refreshNeeded = "TRUE";
	my $menuText;

	my $subname = ( caller(0) )[3];

	# define the main menu as a multiline string
	$menuText = generateMenuHeader( "MINI",
		"Please Wait... Getting latest version details from Atlassian", "" );

	# print the main menu
	system 'clear';
	print $menuText;

	$log->debug("BEGIN: $subname");

	if ( -e $latestVersionsCacheFile ) {

		#Has file been modified within the last 24 hours?
		if ( 1 < -M $latestVersionsCacheFile ) {

			#file is older than 24 hours, refresh needed
			$refreshNeeded = "TRUE";
		}
		else {

			#file has been modified within the last 24 hours - use it as a cache
			%latestVersions = readHashFromFile($latestVersionsCacheFile);
			$refreshNeeded  = "FALSE";
		}
	}

	if ( $refreshNeeded eq "TRUE" ) {
		undef(%latestVersions);
		foreach (@suiteApplications) {
			$application   = $_;
			$lcApplication = lc($application);
			@downloadArray = getLatestDownloadURL( $application, $globalArch );

			$latestVersions{"$application"}{'URL'}     = $downloadArray[0];
			$latestVersions{"$application"}{'version'} = $downloadArray[1];

		}

		#outputAsACache
		dumpHashToFile( $latestVersionsCacheFile, %latestVersions );
	}
}

########################################
#GetBooleanInput                       #
########################################
sub getBooleanInput {
	my $LOOP = 1;
	my $input;
	my $subname = ( caller(0) )[3];
	my $displayLine;

	$log->trace("BEGIN: $subname")
	  ;    #we only want this on trace or it makes the script unusable

	$displayLine = $_[0];

	while ( $LOOP == 1 ) {

		print $displayLine;
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
			$log->debug(
				"$subname: Input not recognised, asking user for input again."
			);
			print "Your input '" . $input
			  . "' was not recognised. Please try again and write yes or no.\n\n";
		}
	}
}

########################################
#getConfigItem                         #
########################################
sub getConfigItem {

#This function can be used if a config item may have a NULL defined deliberately to return the correct value.
	my $configItem;
	my $cfg;
	my @parameterNull;

	$configItem = $_[0];
	$cfg        = $_[1];

	@parameterNull = $cfg->param($configItem);

	if ( ( $#parameterNull == -1 ) ) {
		return "";
	}
	else {
		if ( $cfg->param($configItem) eq "NULL" ) {
			return "";
		}
		else {
			return $cfg->param($configItem);
		}
	}
}

########################################
#getEnvironmentDebugInfo               #
########################################
sub getEnvironmentDebugInfo {

	my @modules;
	my $installedModules;

	if ( $log->is_debug() ) {
		$log->debug(
"BEGIN DUMPING ENVIRONMENTAL DEBUGGING INFO FOR SCRIPT VERSION $scriptVersion"
		);
		$log->debug("DUMPING ENVIRONMENTAL DEBUGGING INFO - BEGIN OS VERSION");
		if ( -e "/etc/redhat-release" ) {
			system("cat /etc/redhat-release >> $logFile");
		}
		elsif ( -e "/usr/bin/lsb_release" ) {
			system("lsb_release -a >> $logFile");
		}
		else {
			system("cat /etc/issue >> $logFile");
		}
		$log->debug("DUMPING ENVIRONMENTAL DEBUGGING INFO - END OS VERSION");
		$log->debug(
			"DUMPING ENVIRONMENTAL DEBUGGING INFO - BEGIN OS UNAME CONFIG");
		system("uname -a >> $logFile");
		$log->debug(
			"DUMPING ENVIRONMENTAL DEBUGGING INFO - END OS UNAME CONFIG");
		$log->debug(
			"DUMPING ENVIRONMENTAL DEBUGGING INFO - BEGIN MEMINFO CONFIG");
		system("cat /proc/meminfo >> $logFile");
		$log->debug(
			"DUMPING ENVIRONMENTAL DEBUGGING INFO - END MEMINFO CONFIG");
		$log->debug(
			"DUMPING ENVIRONMENTAL DEBUGGING INFO - BEGIN CPUINFO CONFIG");
		system("cat /proc/cpuinfo >> $logFile");
		$log->debug(
			"DUMPING ENVIRONMENTAL DEBUGGING INFO - END CPUINFO CONFIG");
		$log->debug(
			"DUMPING ENVIRONMENTAL DEBUGGING INFO - BEGIN LINUX ENV VARIABLES"
		);
		system("env >> $logFile");
		$log->debug(
			"DUMPING ENVIRONMENTAL DEBUGGING INFO - END LINUX ENV VARIABLES");
		$log->debug(
			"DUMPING ENVIRONMENTAL DEBUGGING INFO - BEGIN LINUX PS OUTPUT");
		system("ps -ef >> $logFile");
		$log->debug(
			"DUMPING ENVIRONMENTAL DEBUGGING INFO - END LINUX PS OUTPUT");
		$log->debug(
			"DUMPING ENVIRONMENTAL DEBUGGING INFO - BEGIN JAVA VERSION OUTPUT"
		);
		system("java -version >> $logFile 2>&1");
		$log->debug(
			"DUMPING ENVIRONMENTAL DEBUGGING INFO - END JAVA VERSION OUTPUT");
		$log->debug(
			"DUMPING ENVIRONMENTAL DEBUGGING INFO - BEGIN DF -H OUTPUT");
		system("df -h >> $logFile 2>&1");
		$log->debug("DUMPING ENVIRONMENTAL DEBUGGING INFO - END DF -H OUTPUT");
		$log->debug(
			"DUMPING ENVIRONMENTAL DEBUGGING INFO - BEGIN PERL VERSION OUTPUT"
		);
		system("perl -v >> $logFile 2>&1");
		$log->debug(
			"DUMPING ENVIRONMENTAL DEBUGGING INFO - END PERL VERSION OUTPUT");
		$log->debug(
			"DUMPING ENVIRONMENTAL DEBUGGING INFO - BEGIN PERL MODULES OUTPUT"
		);
		$installedModules = ExtUtils::Installed->new();

		@modules = $installedModules->modules();

		$log->debug( sprintf "%-30s %-20s", "Module", "Version" );
		foreach (@modules) {
			$log->debug( sprintf "%-30s %-20s",
				$_, $installedModules->version($_) );
		}
		$log->debug(
			"DUMPING ENVIRONMENTAL DEBUGGING INFO - END PERL MODULES OUTPUT");
	}
}

########################################
#getEnvironmentVarsFromConfigFile                    #
########################################
sub getEnvironmentVarsFromConfigFile {
	my $inputFile;    #Must Be Absolute Path
	my $searchFor;
	my @data;
	my $referenceVar;
	my $returnValue;
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	$inputFile    = $_[0];
	$referenceVar = $_[1];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_inputFile",    $inputFile );
	dumpSingleVarToLog( "$subname" . "_referenceVar", $referenceVar );

	#Try to open the provided file
	open( my $inputFileHandle, '<', $inputFile )
	  or $log->logdie("Unable to open file: $inputFile");

	# read file into an array
	@data = <$inputFileHandle>;

	close($inputFileHandle);

	#Search for the definition of the provided variable
	$searchFor = "$referenceVar=";
	my ($index1) = grep { $data[$_] =~ /^$searchFor.*/ } 0 .. $#data;

#If no result is found insert a new line before the line found above which contains the JAVA_OPTS variable
	if ( !defined($index1) ) {
		$log->debug("$subname: $referenceVar= not found. Returning NOTFOUND.");
		return "NOTFOUND";
	}

	#Else update the line to have the new parameters that have been specified
	else {
		$log->debug(
			"$subname: $referenceVar= exists, parsing for and returning value."
		);

		#parseLineForValue
		if ( $data[$index1] =~ /^$searchFor\"(.*)\"/ ) {
			$returnValue = $1;
			chomp $returnValue;    #removeNewline
			return $returnValue;
		}
	}
}

########################################
#getExistingSuiteConfig                #
########################################
sub getExistingSuiteConfig {
	my $cfg;                       #We assume we are creating a new config
	my $mode;
	my $input;
	my $defaultValue;
	my @parameterNull;
	my $oldConfig;
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	$mode = "NEW";
	$cfg = new Config::Simple( syntax => 'ini' );

	#Generate Main Suite Configuration
	print
"This will guide you through the generation of the config required for the management of your existing Atlassian suite. Many of the options will gather automagically however some will require manual input. This wizard will guide you through the process.\n\n";

	#Get root installation directory
	genConfigItem(
		$mode,
		$cfg,
		"general.rootInstallDir",
"Please enter the root directory the suite currently installed into. If you don't have a single root directory just keep the default.",
		"/opt/atlassian",
		'(?!^.*/$)^(/.*)',
"The input you entered was not in the valid format of '/folder'. Please ensure you enter the absolute path with a "
		  . "leading '/' and NO trailing '/'.\n\n"
	);

	#Get root data directory
	genConfigItem(
		$mode,
		$cfg,
		"general.rootDataDir",
"Please enter the root directory the suite data/home directories are currently stored. If you don't have a single root directory just keep the default.",
		"/var/atlassian/application-data",
		'(?!^.*/$)^(/.*)',
"The input you entered was not in the valid format of '/folder'. Please ensure you enter the absolute path with a "
		  . "leading '/' and NO trailing '/'.\n\n"
	);

	#Get Proxy configuration
	genBooleanConfigItem( $mode, $cfg, "general.apacheProxy",
		"Do you use Apache as a front end (i.e. proxy) to the suite ", "yes" );

	if ( $cfg->param("general.apacheProxy") eq "TRUE" ) {

		genBooleanConfigItem(
			$mode,
			$cfg,
			"general.apacheProxySingleDomain",
"Do you use a single domain for ALL application in the suite AND do you currently use the same HTTP/HTTPS scheme for all applications managed by this script (i.e. all over HTTP OR all over HTTPS not mixed)",
			"yes"
		);

		if ( $cfg->param("general.apacheProxySingleDomain") eq "TRUE" ) {
			genConfigItem(
				$mode,
				$cfg,
				"general.apacheProxyHost",
"Please enter the base URL that the suite currently resides on (i.e. the proxyName such as yourdomain.com).",
				"",
				$hostnameRegex,
"The input you entered was not in the valid format of 'yourdomain.com' or 'subdomain.yourdomain.com'. Please try again.\n\n"
			);

			genBooleanConfigItem( $mode, $cfg, "general.apacheProxySSL",
				"Do you run the applications(s) over SSL.", "no" );

			genConfigItem(
				$mode,
				$cfg,
				"general.apacheProxyPort",
"Please enter the port number that Apache serves on (80 for HTTP, 443 for HTTPS in standard situations).",
				"80",
				'^([0-9]*)$',
"The input you entered was not a valid port number, please try again.\n\n"
			);
		}
	}

	#Get Crowd configuration
	genBooleanConfigItem( $mode, $cfg, "crowd.enable",
		"Do you currently run Crowd on this server? yes/no ", "yes" );

	if ( $cfg->param("crowd.enable") eq "TRUE" ) {
		getExistingCrowdConfig($cfg);
	}
	else {
		genBooleanConfigItem(
			$mode,
			$cfg,
			"general.externalCrowdInstance",
"Do you currently use an external Crowd instance (i.e. not installed on this host) for Authentication/SSO? yes/no ",
			"yes"
		);
		if ( $cfg->param("general.externalCrowdInstance") eq "TRUE" ) {

			genConfigItem(
				$mode,
				$cfg,
				"general.externalCrowdHostname",
"Please enter the hostname that the external Crowd instance runs on. (eg crowd.yourdomain.com)",
				"",
				$hostnameRegex,
"The input you entered was not in the valid format of yourdomain.com or subdomain.yourdomain.com, please try again.\n\n"
			);

			genConfigItem(
				$mode,
				$cfg,
				"general.externalCrowdPort",
"Please enter the port that the external Crowd instance runs on. (eg 80/443/8095)",
				"8095",
				'^([0-9]*)$',
"The input you entered was not in a valid numerical format, please try again.\n\n"
			);

			genConfigItem(
				$mode,
				$cfg,
				"general.externalCrowdContext",
"Enter the context that the external Crowd instance should runs under (i.e. /crowd or /login). Write NULL to blank out the context.",
				"/crowd",
				'(?!^.*/$)^(/.*)',
"The input you entered was not in the valid format of '/folder'. Please ensure you enter the path with a "
				  . "leading '/' and NO trailing '/'.\n\n"
			);
		}
	}

	#Get Bamboo configuration
	genBooleanConfigItem( $mode, $cfg, "bamboo.enable",
		"Do you currently run Bamboo on this server? yes/no ", "yes" );

	if ( $cfg->param("bamboo.enable") eq "TRUE" ) {
		getExistingBambooConfig($cfg);
	}

	#Get Confluence configuration
	genBooleanConfigItem( $mode, $cfg, "confluence.enable",
		"Do you currently run Confluence on this server? yes/no ", "yes" );

	if ( $cfg->param("confluence.enable") eq "TRUE" ) {
		getExistingConfluenceConfig($cfg);
	}

	#Get Fisheye configuration
	genBooleanConfigItem( $mode, $cfg, "fisheye.enable",
		"Do you currently run Fisheye on this server? yes/no ", "yes" );

	if ( $cfg->param("fisheye.enable") eq "TRUE" ) {
		getExistingFisheyeConfig($cfg);
	}

	#Get JIRA configuration
	genBooleanConfigItem( $mode, $cfg, "jira.enable",
		"Do you currently run JIRA on this server? yes/no ", "yes" );

	if ( $cfg->param("jira.enable") eq "TRUE" ) {
		getExistingJiraConfig($cfg);
	}

	#Get Stash configuration
	genBooleanConfigItem( $mode, $cfg, "stash.enable",
		"Do you currently run Stash on this server? yes/no ", "yes" );

	if ( $cfg->param("stash.enable") eq "TRUE" ) {
		getExistingStashConfig($cfg);
	}

	#Get suite database architecture configuration
	@parameterNull = $cfg->param("general.targetDBType");

	$defaultValue =
	  ""; #this is the first time we are getting config hence no existing value.
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
			$log->debug("$subname: Database arch selected is MySQL");
			$LOOP = 0;
			$cfg->param( "general.targetDBType", "MySQL" );
		}
		elsif (( lc $input ) eq "2"
			|| ( lc $input ) eq "postgresql"
			|| ( lc $input ) eq "postgres"
			|| ( lc $input ) eq "postgre" )
		{
			$log->debug("$subname: Database arch selected is PostgreSQL");
			$LOOP = 0;
			$cfg->param( "general.targetDBType", "PostgreSQL" );
		}
		elsif (( lc $input ) eq "3"
			|| ( lc $input ) eq "oracle" )
		{
			$log->debug("$subname: Database arch selected is Oracle");
			$LOOP = 0;
			$cfg->param( "general.targetDBType", "Oracle" );
		}
		elsif (( lc $input ) eq "4"
			|| ( lc $input ) eq "microsoft sql server"
			|| ( lc $input ) eq "mssql" )
		{
			$log->debug("$subname: Database arch selected is MSSQL");
			$LOOP = 0;
			$cfg->param( "general.targetDBType", "MSSQL" );
		}
		elsif (( lc $input ) eq "5"
			|| ( lc $input ) eq "hsqldb"
			|| ( lc $input ) eq "hsql" )
		{
			$log->debug("$subname: Database arch selected is HSQLDB");
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
		else {
			$log->debug(
"$subname: User did not enter valid input for database selection. Asking for input again."
			);
			print "Your input '" . $input
			  . "'was not recognised. Please try again and enter either 1, 2, 3, 4 or 5. \n\n";
		}
	}
	@parameterNull = $cfg->param("general.dbJDBCJar");

	if ( $cfg->param("general.targetDBType") eq "MySQL" &
		( ( $#parameterNull == -1 ) || $cfg->param("general.dbJDBCJar") eq "" )
	  )
	{
		$log->warn(
"$subname: MySQL has been selected and no valid JDBC entry defined in config. Download MySQL JDBC driver."
		);
		downloadJDBCConnector( "MySQL", $cfg );
	}

	#Write config and reload
	$log->info("Writing out config file to disk.");
	$cfg->write($configFile);
	loadSuiteConfig();
	$globalArch = whichApplicationArchitecture();

	print
"The suite configuration has been gathered successfully. Please press enter to return to the main menu.";
	$input = <STDIN>;
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
		$log->debug("$subname: Input entered was: $input");
		return $input;
	}
}

########################################
#getJavaMemParameter                #
########################################
sub getJavaMemParameter {
	my $inputFile;    #Must Be Absolute Path
	my $referenceVariable;
	my $referenceParameter;
	my $returnValue;
	my $searchFor;
	my @data;
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	$inputFile          = $_[0];
	$referenceVariable  = $_[1];    #such as JAVA_OPTS
	$referenceParameter = $_[2];    #such as Xmx, Xms, -XX:MaxPermSize and so on

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_inputFile",         $inputFile );
	dumpSingleVarToLog( "$subname" . "_referenceVariable", $referenceVariable );
	dumpSingleVarToLog( "$subname" . "_referenceParameter",
		$referenceParameter );

	#Try to open the provided file
	open( my $inputFileHandle, '<', $inputFile )
	  or $log->logdie("Unable to open file: $inputFile");

	# read file into an array
	@data = <$inputFileHandle>;

	close($inputFileHandle);

	$searchFor = $referenceVariable;

	#Search for the provided string in the file array
	my ($index1) = grep { $data[$_] =~ /^$searchFor.*/ } 0 .. $#data;

	my $count = grep( /.*$referenceParameter.*/, $data[$index1] );
	dumpSingleVarToLog( "$subname" . "_count",          $count );
	dumpSingleVarToLog( "$subname" . " ORIGINAL LINE=", $data[$index1] );

	if ( $count == 1 ) {
		$log->debug("$subname: Splitting string to update the memory value.");
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

			$returnValue = $result3 . $result4;
			dumpSingleVarToLog( "$subname" . " _returnValue", $returnValue );
			return $returnValue;
		}
	}
	else {
		$log->debug(
			"$subname: $referenceParameter does not exist, returning NOTFOUND."
		);
		return "NOTFOUND";
	}
}

########################################
#Get the latest URL to download XXX    #
########################################
sub getLatestDownloadURL {
	my $application;
	my $architecture;
	my @returnArray;
	my $decoded_json;
	my $lcApplication;
	my $jsonField;
	my $descriptionSearchString;
	my $platformSearchString;
	my $urlSearchString;
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	$application  = $_[0];
	$architecture = $_[1];

	$lcApplication = lc($application);

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_application",  $application );
	dumpSingleVarToLog( "$subname" . "_architecture", $architecture );

	#Build URL to check latest version for a particular application
	my $versionurl = "https://my.atlassian.com/download/feeds/current/"
	  . $lcApplication . ".json";
	dumpSingleVarToLog( "$subname" . "_versionurl", $versionurl );

#For each application define the file type that we are looking for in the json feed
	if ( $lcApplication eq "confluence" ) {
		$descriptionSearchString = ".*standalone.*tar.gz.*";
		$platformSearchString    = ".*unix.*";
		$urlSearchString         = ".*tar.gz";
	}
	elsif ( $lcApplication eq "jira" ) {
		$descriptionSearchString = ".*tar.gz.*";
		$platformSearchString    = ".*unix.*";
		$urlSearchString         = ".*tar.gz";
	}
	elsif ( $lcApplication eq "stash" ) {
		$descriptionSearchString = ".*tar.gz.*";
		$platformSearchString    = ".*unix.*";
		$urlSearchString         = ".*tar.gz";
	}
	elsif ( $lcApplication eq "fisheye" ) {
		$descriptionSearchString = ".*fisheye.*";
		$platformSearchString    = ".*unix.*";
		$urlSearchString         = ".*zip";
	}
	elsif ( $lcApplication eq "crowd" ) {
		$descriptionSearchString = ".*standalone.*tar.gz.*";
		$platformSearchString    = ".*unix.*";
		$urlSearchString         = ".*tar.gz";
	}
	elsif ( $lcApplication eq "bamboo" ) {
		$descriptionSearchString = ".*tar.gz.*";
		$platformSearchString    = ".*unix.*";
		$urlSearchString         = ".*tar.gz";
	}
	else {
		print
"That application ($application) is not recognised - Really you should never get here so if you managed to *wavesHi*";
		exit 2;
	}

	dumpSingleVarToLog( "$subname" . "_descriptionSearchString",
		$descriptionSearchString );
	dumpSingleVarToLog( "$subname" . "_platformSearchString",
		$platformSearchString );
	dumpSingleVarToLog( "$subname" . "_urlSearchString", $urlSearchString );

	print
"Downloading and parsing the Atlassian feed for the latest version of $application please wait...\n\n";

	#Try and download the feed
	$ua->show_progress(0);
	my $json = get($versionurl);
	$log->logdie("JSON Download: Could not get $versionurl!")
	  unless defined $json;

 #We have to rework the string slightly as Atlassian is not returning valid JSON
	$json = substr( $json, 10, -1 );
	$json = '{ "downloads": ' . $json . '}';

	# Decode the entire JSON
	$decoded_json = decode_json($json);

  #Loop through the feed and find the specific file we want for this application
	for my $item ( @{ $decoded_json->{downloads} } ) {
		foreach ($item) {
			if ( ( lc( $item->{"description"} ) =~ /$descriptionSearchString/ )
				&& ( lc( $item->{"platform"} ) =~ /$platformSearchString/ )
				&& ( lc( $item->{"zipUrl"} )   =~ /$urlSearchString/ ) )
			{
				@returnArray = ( $item->{zipUrl}, $item->{version} );
				dumpSingleVarToLog( "$subname" . "_zipUrl",  $item->{zipUrl} );
				dumpSingleVarToLog( "$subname" . "_version", $item->{version} );
				return @returnArray;
			}
		}
	}
}

########################################
#getLineFromFile                       #
########################################
sub getLineFromFile {
	my $inputFile;    #Must Be Absolute Path
	my $lineReference;
	my $searchFor;
	my @data;
	my $returnValue;
	my $valueRegex;
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	$inputFile     = $_[0];
	$lineReference = $_[1];
	$valueRegex    = $_[2];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_inputFile",     $inputFile );
	dumpSingleVarToLog( "$subname" . "_lineReference", $lineReference );
	dumpSingleVarToLog( "$subname" . "_valueRegex",    $valueRegex );
	open( my $inputFileHandle, '<', $inputFile )
	  or $log->logdie("Unable to open file: $inputFile: $!");

	# read file into an array
	@data = <$inputFileHandle>;

	close($inputFileHandle);

	#Search for reference line
	my ($index1) =
	  grep { $data[$_] =~ /^$lineReference.*/ } 0 .. $#data;

	#If you cant find the first reference try for the second reference
	if ( !defined($index1) ) {
		$log->debug("$subname: First search term $lineReference not found.");
		return "NOTFOUND";
	}
	else {

		#parseLineForValue
		if ( $data[$index1] =~ /$valueRegex/ ) {
			$returnValue = $1;
			$returnValue =~ tr/\015//d;    #trim unusual newlines
			$returnValue =~ tr/\"//d;      #trim unusual newlines
			return $returnValue;
		}
		else {
			$log->debug("$subname: Search regex not found in line.");
			return "NOTFOUND2";
		}
	}
}

########################################
#getLineFromBambooWrapperConf          #
#This is the GET function which matches#
#the update/set function               #
#defined in [#ATLASMGR-143]            #
########################################
sub getLineFromBambooWrapperConf {
	my $inputFile;    #Must Be Absolute Path
	my $variableReference;
	my $searchFor;
	my $parameterReference;
	my $newValue;
	my @data;
	my $index1;
	my $line;
	my $returnValue;
	my $count   = 0;
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	$inputFile          = $_[0];
	$variableReference  = $_[1];
	$parameterReference = $_[2];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_inputFile",         $inputFile );
	dumpSingleVarToLog( "$subname" . "_variableReference", $variableReference );
	dumpSingleVarToLog( "$subname" . "_parameterReference",
		$parameterReference );
	open( my $inputFileHandle, '<', $inputFile )
	  or $log->logdie("Unable to open file: $inputFile: $!");

	# read file into an array
	@data = <$inputFileHandle>;

	close($inputFileHandle);

	#Search for reference line
	($index1) =
	  grep { $data[$_] =~ /.*$parameterReference.*/ } 0 .. $#data;
	if ( !defined($index1) ) {
		$log->debug(
"$subname: Line with $parameterReference not found. Returning NOTFOUND."
		);

		return "NOTFOUND";
	}
	else {

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

			$returnValue = $result5;
			$returnValue =~ tr/\015//d;    #trim unusual newlines
			dumpSingleVarToLog( "$subname" . " _returnValue", $returnValue );
			return $returnValue;
		}
	}
}

########################################
#getPIDList                            #
########################################
sub getPIDList {
	my @PIDs;
	my $line;
	my $i;
	my $grep1stParam;
	my $grep2ndParam;
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");
	$grep1stParam = $_[0];
	$grep2ndParam = $_[1];
	dumpSingleVarToLog( "$subname" . "_grep1stParam", $grep1stParam );
	dumpSingleVarToLog( "$subname" . "_grep2ndParam", $grep2ndParam );

	@PIDs =
`/bin/ps -ef | grep $grep1stParam | grep $grep2ndParam | grep -v 'ps -ef | grep'`;
	return @PIDs;
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

	$log->debug("BEGIN: $subname");

	$osUser = $_[0];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_osUser", $osUser );

	( $login, $pass, $uid, $gid ) = getpwnam($osUser)
	  or $log->logdie(
"$osUser not in passwd file. This is not good and is kinda fatal. Please contact support with a copy of your logs."
	  );

	@return = ( $uid, $gid );
	dumpSingleVarToLog( "$subname" . "_uid", $uid );
	dumpSingleVarToLog( "$subname" . "_gid", $gid );
	return @return;
}

########################################
#Get specific version URL to download  #
########################################
sub getVersionDownloadURL {
	my $application;
	my $lcApplication;
	my $architecture;
	my $filename;
	my $fileExt;
	my $version;
	my @returnArray;
	my $versionurl;
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	$application   = $_[0];
	$architecture  = $_[1];
	$version       = $_[2];
	$lcApplication = lc($application);

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_application",  $application );
	dumpSingleVarToLog( "$subname" . "_architecture", $architecture );
	dumpSingleVarToLog( "$subname" . "_version",      $version );

	#Generate application specific URL
	$versionurl =
	    "http://www.atlassian.com/software/"
	  . $lcApplication
	  . "/downloads/binary";
	dumpSingleVarToLog( "$subname" . "_versionurl", $versionurl );

#For each application generate the file name based on known information and input data
	if ( $lcApplication eq "confluence" ) {
		$fileExt  = "tar.gz";
		$filename = "atlassian-confluence-" . $version . "." . $fileExt;
	}
	elsif ( $lcApplication eq "jira" ) {
		$fileExt  = "tar.gz";
		$filename = "atlassian-jira-" . $version . "." . $fileExt;
	}
	elsif ( $lcApplication eq "stash" ) {
		$fileExt  = "tar.gz";
		$filename = "atlassian-stash-" . $version . "." . $fileExt;
	}
	elsif ( $lcApplication eq "fisheye" ) {
		$fileExt  = "zip";
		$filename = "fisheye-" . $version . "." . $fileExt;
	}
	elsif ( $lcApplication eq "crowd" ) {
		$fileExt  = "tar.gz";
		$filename = "atlassian-crowd-" . $version . "." . $fileExt;
	}
	elsif ( $lcApplication eq "bamboo" ) {
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
#getXMLAttribute                       #
########################################
sub getXMLAttribute {

	my $xmlFile;    #Must Be Absolute Path
	my $searchString;
	my $referenceAttribute;
	my $attributeReturnValue;
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	$xmlFile            = $_[0];
	$searchString       = $_[1];
	$referenceAttribute = $_[2];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_xmlFile",      $xmlFile );
	dumpSingleVarToLog( "$subname" . "_searchString", $searchString );
	dumpSingleVarToLog( "$subname" . "_referenceAttribute",
		$referenceAttribute );

	#Set up new XML object, with "pretty" spacing (i.e. standard spacing)
	my $twig = new XML::Twig( pretty_print => 'indented' );

	#Parse the XML file
	$twig->parsefile($xmlFile);

	#Find the node we are looking for based on the provided search string
	for my $node ( $twig->findnodes($searchString) ) {
		$log->debug(
"$subname: Found $searchString in $xmlFile. Getting the attribute value."
		);

		#Set the node to the new attribute value
		$attributeReturnValue = $node->att($referenceAttribute);
		if ( !defined $attributeReturnValue ) {
			return "NOTFOUND";
		}
		else {
			return $attributeReturnValue;
		}
	}
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
	my @tomcatParameterNull;
	my @webappParameterNull;
	my $tomcatDir;
	my $webappDir;
	my $removeDownloadedDataAnswer;
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	$application         = $_[0];
	$downloadArchivesUrl = $_[1];
	@requiredConfigItems = @{ $_[2] };

	$lcApplication = lc($application);

#Iterate through required config items, if any are missing force an update of configuration
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
		$input = getBooleanInput(
"Would you like to review the $application config before installing? Yes/No [no]: "
		);
		print "\n";
		if ( $input eq "yes" ) {
			$log->info(
				"$subname: User opted to update config prior to installation."
			);
			generateApplicationConfig( $application, "UPDATE", $globalConfig );
			$log->info("Writing out config file to disk.");
			$globalConfig->write($configFile);
			loadSuiteConfig();
		}
	}

	#set up the tomcat and webapp parameters as sometimes they are null
	@tomcatParameterNull = $globalConfig->param("$lcApplication.tomcatDir");
	@webappParameterNull = $globalConfig->param("$lcApplication.webappDir");

	if ( $#tomcatParameterNull == -1 ) {
		$tomcatDir = "";
	}
	else {
		$tomcatDir = $globalConfig->param("$lcApplication.tomcatDir");

	}

	if ( $#webappParameterNull == -1 ) {
		$webappDir = "";
	}
	else {
		$webappDir = $globalConfig->param("$lcApplication.webappDir");

	}

	$serverPortAvailCode =
	  isPortAvailable( $globalConfig->param("$lcApplication.serverPort") );

	$connectorPortAvailCode =
	  isPortAvailable( $globalConfig->param("$lcApplication.connectorPort") );

	if ( $serverPortAvailCode == 0 || $connectorPortAvailCode == 0 ) {
		$log->info(
"$subname: ServerPortAvailCode=$serverPortAvailCode, ConnectorPortAvailCode=$connectorPortAvailCode. Whichever one equals 0 
is currently in use. We will continue however there is a good chance $application will not start."
		);
		print
"One or more of the ports configured for $application are currently in use. We can proceed however there is a very good chance"
		  . " that $application will not start correctly.\n\n";

		$input = getBooleanInput(
"Would you like to continue even though the ports are in use? yes/no [yes]: "
		);
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

	$input = getBooleanInput(
		"Would you like to install the latest version? yes/no [yes]: ");
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
			$ua->show_progress(0);

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

	#Check if user wants to remove the downloaded archive
	$removeDownloadedDataAnswer = getBooleanInput(
"Do you wish to delete the downloaded archive after the installation is complete? [no]: "
	);
	print "\n";

	#Get the user the application will run as
	$osUser = $globalConfig->param("$lcApplication.osUser");

	#Check the user exists or create if not
	createOSUser( $osUser, $application );

	print "\n";

	print "We now have enough information to complete the install. \n\n";

	print
"When you are ready to proceed with the install press enter. If you wish to cancel the upgrade please type 'q' and press return. ";
	$input = <STDIN>;
	print "\n\n";

	chomp($input);
	if ( lc($input) eq "q" ) {

		#Bail out and cancel the install.
		print "Install has been cancelled, this script will now terminate.\n\n";
		$input = <STDIN>;
		print "\n\n";
		exit 0;
	}

	#Download the latest version
	if ( $mode eq "LATEST" ) {
		$log->info("$subname: Downloading latest version of $application");
		@downloadDetails =
		  downloadAtlassianInstaller( $mode, $application, "", $globalArch );
		$version = $downloadDetails[1];

	}

	#Download a specific version
	else {
		$log->info("$subname: Downloading version $version of $application");
		@downloadDetails =
		  downloadAtlassianInstaller( $mode, $application, $version,
			$globalArch );
	}

	#Extract the download and move into place
	$log->info("$subname: Extracting $downloadDetails[2]...");
	extractAndMoveFile( $downloadDetails[2],
		escapeFilePath( $globalConfig->param("$lcApplication.installDir") ),
		$osUser, "" );

	#Remove downloaded data if user opted to do so
	if ( $removeDownloadedDataAnswer eq "yes" ) {
		$log->info("$subname: User opted to delete downloaded installer.");
		unlink $downloadDetails[2]
		  or warn "Could not delete " . $downloadDetails[2] . ": $!";
	}

	#Update config to reflect new version that is installed
	$log->debug("$subname: Writing new installed version to the config file.");
	$globalConfig->param( "$lcApplication.installedVersion", $version );
	$log->info("Writing out config file to disk.");
	$globalConfig->write($configFile);
	loadSuiteConfig();

#If MySQL is the Database, Atlassian apps do not come with the driver so copy it
	if ( $globalConfig->param("general.targetDBType") eq "MySQL" ) {
		$log->info(
"$subname: Copying MySQL JDBC connector to $application install directory."
		);

		if ( $tomcatDir eq "" ) {
			createAndChownDirectory(
				escapeFilePath(
					$globalConfig->param("$lcApplication.installDir")
				  )
				  . "/lib/",
				$osUser
			);
		}
		else {
			createAndChownDirectory(
				escapeFilePath(
					$globalConfig->param("$lcApplication.installDir")
				  )
				  . $tomcatDir . "/lib/",
				$osUser
			);
		}

		print
"Database is configured as MySQL, copying the JDBC connector to $application install.\n\n";
		dumpSingleVarToLog( "$subname" . "_tomcatDir", $version );
		if ( $tomcatDir eq "" ) {
			copyFile(
				$globalConfig->param("general.dbJDBCJar"),
				escapeFilePath(
					$globalConfig->param("$lcApplication.installDir")
				  )
				  . "/lib/"
			);
		}
		else {
			copyFile(
				$globalConfig->param("general.dbJDBCJar"),
				escapeFilePath(
					$globalConfig->param("$lcApplication.installDir")
				  )
				  . $tomcatDir . "/lib/"
			);
		}

		#Chown the files again
		if ( $tomcatDir eq "" ) {
			$log->debug( "$subname: Chowning "
				  . $globalConfig->param( $lcApplication . ".installDir" )
				  . "/lib/"
				  . " to $osUser following MySQL JDBC install." );
			chownRecursive(
				$osUser,
				escapeFilePath(
					$globalConfig->param("$lcApplication.installDir")
				  )
				  . "/lib/"
			);
		}
		else {
			$log->debug( "$subname: Chowning "
				  . $globalConfig->param( $lcApplication . ".installDir" )
				  . $tomcatDir . "/lib/"
				  . " to $osUser following MySQL JDBC install." );
			chownRecursive(
				$osUser,
				escapeFilePath(
					$globalConfig->param("$lcApplication.installDir")
				  )
				  . $tomcatDir . "/lib/"
			);
		}
	}

	#Create home/data directory if it does not exist
	$log->info(
"$subname: Checking for and creating $application home directory (if it does not exist)."
	);
	print
"Checking if data directory exists and creating if not, please wait...\n\n";
	createAndChownDirectory(
		escapeFilePath( $globalConfig->param("$lcApplication.dataDir") ),
		$osUser );

	#GenericInstallCompleted
}

########################################
#Check if port is defined elsewhere    #
########################################
sub isPortDefinedElsewhere {
	my $application;
	my $lcApplication;
	my $lcApplicationToCheck;
	my $applicationToCheck;
	my @parameterNull;
	my @portTypes = ( "serverPort", "connectorPort" );
	my $portType;
	my @returnDetails;
	my $port;
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	$application   = $_[0];
	$port          = $_[1];
	$lcApplication = lc($application);

	foreach (@suiteApplications) {
		$applicationToCheck   = $_;
		$lcApplicationToCheck = lc($applicationToCheck);
		if ( $application ne $applicationToCheck ) {
			foreach (@portTypes) {
				my $portType = $_;
				@parameterNull =
				  $globalConfig->param("$lcApplicationToCheck.$portType");
				if ( $#parameterNull == -1 ) {
					$log->debug(
"$subname: Port $port is not in use by $application. Continuing..."
					);
				}
				else {
					if ( $globalConfig->param("$lcApplicationToCheck.$portType")
						eq "$port" )
					{
						$log->debug(
"$subname: Port $port is already defined for use by $lcApplication.$portType."
						);
						push( @returnDetails,
							$applicationToCheck . " - " . $portType );
					}
				}
			}
		}
	}
	return @returnDetails;
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
#isSupportedVersion                   #
########################################
sub isSupportedVersion {
	my $application;
	my $lcApplication;
	my $version;
	my $productVersion;
	my $count;
	my $versionReturn;
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	$application   = $_[0];
	$version       = $_[1];
	$lcApplication = lc($application);

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_application", $application );
	dumpSingleVarToLog( "$subname" . "_version",     $version );

	#Set up maximum supported versions
	my $jiraSupportedVerHigh =
	  $supportedVersionsConfig->param("$scriptVersion.jira");
	my $confluenceSupportedVerHigh =
	  $supportedVersionsConfig->param("$scriptVersion.confluence");
	my $crowdSupportedVerHigh =
	  $supportedVersionsConfig->param("$scriptVersion.crowd");
	my $fisheyeSupportedVerHigh =
	  $supportedVersionsConfig->param("$scriptVersion.fisheye");
	my $bambooSupportedVerHigh =
	  $supportedVersionsConfig->param("$scriptVersion.bamboo");
	my $stashSupportedVerHigh =
	  $supportedVersionsConfig->param("$scriptVersion.stash");

	#Set up supported version for each product
	if ( $lcApplication eq "confluence" ) {
		$productVersion = $confluenceSupportedVerHigh;
	}
	elsif ( $lcApplication eq "jira" ) {
		$productVersion = $jiraSupportedVerHigh;
	}
	elsif ( $lcApplication eq "stash" ) {
		$productVersion = $stashSupportedVerHigh;
	}
	elsif ( $lcApplication eq "fisheye" ) {
		$productVersion = $fisheyeSupportedVerHigh;
	}
	elsif ( $lcApplication eq "crowd" ) {
		$productVersion = $crowdSupportedVerHigh;
	}
	elsif ( $lcApplication eq "bamboo" ) {
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
		$log->debug(
"$subname: Version provided ($version) of $application is supported (max supported version is $productVersion)."
		);
		return "yes";
	}
	else {
		$log->debug(
"$subname: Version provided ($version) of $application is NOT supported (max supported version is $productVersion)."
		);
		return "no";
	}
}

########################################
#LoadSuiteConfig                       #
########################################
sub loadSuiteConfig {

	#Test if config file exists, if so load it
	if ( -e $configFile ) {
		$globalConfig = new Config::Simple($configFile);
	}

	#Test if config file exists, if so load it
	if ( -e $supportedVersionsConfigFile ) {
		$supportedVersionsConfig =
		  new Config::Simple($supportedVersionsConfigFile);
	}
}

########################################
#Manage Service                        #
########################################
sub manageService {
	my $application;
	my $lcApplication;
	my $mode;
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	$application   = $_[0];
	$mode          = $_[1];
	$lcApplication = lc($application);

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_application", $application );
	dumpSingleVarToLog( "$subname" . "_mode",        $mode );

	#Install the service
	if ( $mode eq "INSTALL" ) {
		$log->info("Installing Service for $application.");
		print "Installing Service for $application...\n\n";
		if ( $distro eq "redhat" ) {
			system("chkconfig --add $lcApplication") == 0
			  or $log->warn("Adding $application as a service failed: $?");
		}
		elsif ( $distro eq "debian" ) {
			system("update-rc.d $lcApplication defaults") == 0
			  or $log->warn("Adding $application as a service failed: $?");
		}
		print "Service installed successfully...\n\n";
	}

	#Remove the service
	elsif ( $mode eq "UNINSTALL" ) {
		$log->info("Removing Service for $application.");
		print "Removing Service for $application...\n\n";
		if ( $distro eq "redhat" ) {
			system("chkconfig --del $lcApplication") == 0
			  or $log->warn("Removing $application as a service failed: $?");
		}
		elsif ( $distro eq "debian" ) {
			system("update-rc.d -f $lcApplication remove") == 0
			  or $log->warn("Removing $application as a service failed: $?");

		}
		print "Service removed successfully...\n\n";
	}
}

########################################
#MoveDirectory                         #
########################################
sub moveDirectory {
	my $origDirectory;
	my $newDirectory;
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	$origDirectory = $_[0];
	$newDirectory  = $_[1];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_origDirectory", $origDirectory );
	dumpSingleVarToLog( "$subname" . "_newDirectory",  $newDirectory );

	$log->debug("$subname: Moving $origDirectory to $newDirectory.");

	if ( move( $origDirectory, $newDirectory ) == 0 ) {
		$log->logdie(
"Unable to move folder $origDirectory to $newDirectory. Unknown error occured.\n\n"
		);
	}
}

########################################
#MoveFile                              #
########################################
sub moveFile {
	my $origFile;
	my $newFile;
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	$origFile = $_[0];
	$newFile  = $_[1];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_origFile", $origFile );
	dumpSingleVarToLog( "$subname" . "_newFile",  $newFile );

	$log->debug("$subname: Moving $origFile to $newFile.");

	if ( move( $origFile, $newFile ) == 0 ) {
		$log->logdie(
"Unable to move file $origFile to $newFile. Unknown error occured.\n\n"
		);
	}
}

########################################
#PostInstallGeneric                    #
########################################
sub postInstallGeneric {
	my $application;
	my $lcApplication;
	my $input;
	my $osUser;
	my $url;
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	$application = $_[0];

	$lcApplication = lc($application);
	$osUser        = $globalConfig->param("$lcApplication.osUser");

	#If set to run as a service, set to run on startup
	if ( $globalConfig->param("$lcApplication.runAsService") eq "TRUE" ) {
		$log->info(
			"$subname: Setting up $application as a service to run on startup."
		);
		manageService( $application, "INSTALL" );
	}
	print "Services configured successfully.\n\n";

	#Check if we should start the service
	$input = getBooleanInput(
"Installation has completed successfully. Would you like to start the $application service now? Yes/No [yes]: "
	);
	print "\n";
	if ( $input eq "default" || $input eq "yes" ) {
		$log->info("$subname: User opted to start application service.");
		my $processReturnCode = startService(
			$application,
			"\""
			  . $globalConfig->param(
				$lcApplication . ".processSearchParameter1"
			  )
			  . "\"",
			"\""
			  . $globalConfig->param(
				$lcApplication . ".processSearchParameter2"
			  )
			  . "\""
		);
		if ( $processReturnCode eq "SUCCESS" ) {
			if ( $globalConfig->param("general.apacheProxy") eq "TRUE" ) {
				if ( $globalConfig->param("general.apacheProxySingleDomain") eq
					"TRUE" )
				{
					if ( $globalConfig->param("general.apacheProxySSL") eq
						"TRUE" )
					{
						$url =
						    "https://"
						  . $globalConfig->param("general.apacheProxyHost")
						  . ":"
						  . $globalConfig->param("general.apacheProxyPort")
						  . getConfigItem( "$lcApplication.appContext",
							$globalConfig );
					}
					else {
						$url =
						    "http://"
						  . $globalConfig->param("general.apacheProxyHost")
						  . ":"
						  . $globalConfig->param("general.apacheProxyPort")
						  . getConfigItem( "$lcApplication.appContext",
							$globalConfig );
					}
				}
				else {
					if (
						$globalConfig->param("$lcApplication.apacheProxySSL") eq
						"TRUE" )
					{
						$url =
						  "https://"
						  . $globalConfig->param(
							"$lcApplication.apacheProxyHost")
						  . ":"
						  . $globalConfig->param(
							"$lcApplication.apacheProxyPort")
						  . getConfigItem( "$lcApplication.appContext",
							$globalConfig );
					}
					else {
						$url =
						  "http://"
						  . $globalConfig->param(
							"$lcApplication.apacheProxyHost")
						  . ":"
						  . $globalConfig->param(
							"$lcApplication.apacheProxyPort")
						  . getConfigItem( "$lcApplication.appContext",
							$globalConfig );
					}
				}
				print "\n"
				  . "$application can now be accessed on $url" . ".\n\n";
			}
			else {
				print "\n"
				  . "$application can now be accessed on http://localhost:"
				  . $globalConfig->param("$lcApplication.connectorPort")
				  . getConfigItem( "$lcApplication.appContext", $globalConfig )
				  . ".\n\n";
			}
		}
		else {
			print
"\n The service could not be started correctly please ensure you do this manually.\n\n";
		}
	}

	#refresh some details within the script
	checkForAvailableUpdates();
	generateAvailableUpdatesString();

	print
"The $application install has completed. Please visit the web interface and follow the steps to complete the web install wizard. When you have completed this please press enter to continue...";
	$input = <STDIN>;
}

########################################
#PostUpgradeGeneric                    #
########################################
sub postUpgradeGeneric {
	my $application;
	my $lcApplication;
	my $input;
	my $osUser;
	my $url;
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	$application = $_[0];

	$lcApplication = lc($application);
	$osUser        = $globalConfig->param("$lcApplication.osUser");

	#If set to run as a service, set to run on startup
	if ( $globalConfig->param("$lcApplication.runAsService") eq "TRUE" ) {
		$log->info(
			"$subname: Setting up $application as a service to run on startup."
		);
		manageService( $application, "INSTALL" );
	}
	print "Services configured successfully.\n\n";

	#Check if we should start the service
	$input = getBooleanInput(
"The upgrade has completed successfully. Would you like to start the $application service now? Yes/No [yes]: "
	);
	print "\n";
	if ( $input eq "default" || $input eq "yes" ) {
		$log->info("$subname: User opted to start application service.");
		my $processReturnCode = startService(
			$application,
			"\""
			  . $globalConfig->param(
				$lcApplication . ".processSearchParameter1"
			  )
			  . "\"",
			"\""
			  . $globalConfig->param(
				$lcApplication . ".processSearchParameter2"
			  )
			  . "\""
		);
		if ( $processReturnCode eq "SUCCESS" ) {
			if ( $globalConfig->param("general.apacheProxy") eq "TRUE" ) {
				if ( $globalConfig->param("general.apacheProxySingleDomain") eq
					"TRUE" )
				{
					if ( $globalConfig->param("general.apacheProxySSL") eq
						"TRUE" )
					{
						$url =
						    "https://"
						  . $globalConfig->param("general.apacheProxyHost")
						  . ":"
						  . $globalConfig->param("general.apacheProxyPort")
						  . getConfigItem( "$lcApplication.appContext",
							$globalConfig );
					}
					else {
						$url =
						    "http://"
						  . $globalConfig->param("general.apacheProxyHost")
						  . ":"
						  . $globalConfig->param("general.apacheProxyPort")
						  . getConfigItem( "$lcApplication.appContext",
							$globalConfig );
					}
				}
				else {
					if (
						$globalConfig->param("$lcApplication.apacheProxySSL") eq
						"TRUE" )
					{
						$url =
						  "https://"
						  . $globalConfig->param(
							"$lcApplication.apacheProxyHost")
						  . ":"
						  . $globalConfig->param(
							"$lcApplication.apacheProxyPort")
						  . getConfigItem( "$lcApplication.appContext",
							$globalConfig );
					}
					else {
						$url =
						  "http://"
						  . $globalConfig->param(
							"$lcApplication.apacheProxyHost")
						  . ":"
						  . $globalConfig->param(
							"$lcApplication.apacheProxyPort")
						  . getConfigItem( "$lcApplication.appContext",
							$globalConfig );
					}
				}
				print "\n"
				  . "$application can now be accessed on $url" . ".\n\n";
			}
			else {
				print "\n"
				  . "$application can now be accessed on http://localhost:"
				  . $globalConfig->param("$lcApplication.connectorPort")
				  . getConfigItem( "$lcApplication.appContext", $globalConfig )
				  . ".\n\n";
			}
		}
		else {
			print
"\n The service could not be started correctly please ensure you do this manually.\n\n";
		}
	}

	#refresh some details within the script
	checkForAvailableUpdates();
	generateAvailableUpdatesString();

	print
"The $application upgrade has completed successfully. Please press enter to return to the main menu.";
	$input = <STDIN>;
}

########################################
#readHashFromFile                      #
########################################
sub readHashFromFile {
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	#Code below - thanks go to Kyle on http://www.perlmonks.org/?node_id=704380

	my ($fileName) = @_;

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_fileName", $fileName );

	open my $fh, '<', $fileName
	  or die "Can't read '$fileName': $!";
	local $/ = undef;    # read whole file
	my $dumped = <$fh>;
	close $fh or log->logdie("Can't close '$fileName': $!\n\n");
	return %{ eval $dumped };
}

########################################
#RemoveDirector(ies)                   #
#Takes an array of directories in      #
########################################
sub removeDirs {
	my $directory;
	my $escapedDirectory;
	my $subname = ( caller(0) )[3];
	my @directoryList;

	$log->debug("BEGIN: $subname");

	@directoryList = @_;

	foreach (@directoryList) {
		$directory        = $_;
		$escapedDirectory = escapeFilePath($directory);

		#removeDirectories
		$log->debug( "$subname: Removing " . $escapedDirectory );
		if ( -d $escapedDirectory ) {
			rmtree( [$escapedDirectory] );
		}
		else {
			$log->debug( "$subname: Unable to remove "
				  . $escapedDirectory
				  . ". Directory does not exist." );
		}
	}

}

########################################
#restartService                        #
########################################
sub restartService {
	my @PIDs;
	my $application;
	my $lcApplication;
	my $grep1stParam;
	my $grep2ndParam;
	my $startReturn;
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");
	$application   = $_[0];
	$lcApplication = lc($application);
	$grep1stParam  = $_[1];
	$grep2ndParam  = $_[2];
	dumpSingleVarToLog( "$subname" . "_application",  $application );
	dumpSingleVarToLog( "$subname" . "_grep1stParam", $grep1stParam );
	dumpSingleVarToLog( "$subname" . "_grep2ndParam", $grep2ndParam );

	if (
		stopService( $application, $grep1stParam, $grep2ndParam ) eq "SUCCESS" )
	{
		$log->info("$subname: Service stop for $application succeeded.");
		$startReturn =
		  startService( $application, $grep1stParam, $grep2ndParam );

		if ( $startReturn eq "SUCCESS" ) {
			$log->info("$subname: Service start for $application succeeded.");
			return "SUCCESS";
		}
		elsif ( $startReturn eq "FAIL" ) {
			$log->info("$subname: Service start for $application failed.");
			return "FAIL";
		}
		elsif ( $startReturn eq "WARN" ) {
			$log->info(
				"$subname: Service start for $application returned 'WARN'.");
			return "WARN";
		}
	}
	else {
		$log->info("$subname: Service stop for $application failed.");
		return "FAIL";
	}
}

########################################
#restoreApplicationBackup              #
########################################
sub restoreApplicationBackup {
	my $subname = ( caller(0) )[3];
	my $date = strftime "%Y%m%d_%H%M%S", localtime;
	my $application;
	my $lcApplication;
	my $input;
	my $compressedInstallDirBackup;
	my $compressedDataDirBackup;
	my $installDirFolder;
	my $dataDirFolder;
	my $installDirPath;
	my $dataDirPath;
	my $installDirBackupLocation;
	my $dataDirBackupLocation;

	$log->debug("BEGIN: $subname");
	$application   = $_[0];
	$lcApplication = lc($application);

	#set up some parameters
	$installDirFolder =
	  basename(
		escapeFilePath( $globalConfig->param("$lcApplication.installDir") ) );
	$dataDirFolder =
	  basename(
		escapeFilePath( $globalConfig->param("$lcApplication.dataDir") ) );
	$installDirPath =
	  dirname(
		escapeFilePath( $globalConfig->param("$lcApplication.installDir") ) );
	$dataDirPath =
	  dirname(
		escapeFilePath( $globalConfig->param("$lcApplication.dataDir") ) );
	$installDirBackupLocation =
	  $globalConfig->param("$lcApplication.latestInstallDirBackupLocation");
	$dataDirBackupLocation =
	  $globalConfig->param("$lcApplication.latestDataDirBackupLocation");

	print
"You have selected to restore the previous backup for $application. Please be aware this will NOT restore your database and this MUST be done separately.\n";
	print
"By continuing this script will immediately stop the services and restore $application without any further confirmation.\n\n";
	$input = getBooleanInput("Do you *really* want to continue? yes/no [no]: ");
	print "\n";
	if ( $input eq "no" || $input eq "default" ) {
		return;
	}

	stopService(
		$application,
		"\""
		  . $globalConfig->param( $lcApplication . ".processSearchParameter1" )
		  . "\"",
		"\""
		  . $globalConfig->param( $lcApplication . ".processSearchParameter2" )
		  . "\""
	);

	if ( $dataDirBackupLocation =~ /.*\.tar\.gz$/ ) {
		$compressedDataDirBackup = "TRUE";
		unless ( -e $dataDirBackupLocation ) {
			$log->logdie(
"The Data Directory backup does not exist. Unfortunately we are unable to proceed. The script will now terminate."
			);
		}
	}
	else {
		$compressedDataDirBackup = "FALSE";
		unless ( -d $dataDirBackupLocation ) {
			$log->logdie(
"The Data Directory backup does not exist. Unfortunately we are unable to proceed. The script will now terminate."
			);
		}
	}

	if ( $installDirBackupLocation =~ /.*\.tar\.gz$/ ) {
		$compressedInstallDirBackup = "TRUE";
		unless ( -e $installDirBackupLocation ) {
			$log->logdie(
"The Installation Directory backup does not exist. Unfortunately we are unable to proceed. The script will now terminate."
			);
		}

	}
	else {
		$compressedInstallDirBackup = "FALSE";
		unless ( -d $installDirBackupLocation ) {
			$log->logdie(
"The Installation Directory backup does not exist. Unfortunately we are unable to proceed. The script will now terminate."
			);
		}
	}

	#Move broken install directories
	moveDirectory( $globalConfig->param("$lcApplication.installDir"),
		$globalConfig->param("$lcApplication.installDir")
		  . "_prerestore_$date" );
	moveDirectory( $globalConfig->param("$lcApplication.dataDir"),
		$globalConfig->param("$lcApplication.dataDir") . "_prerestore_$date" );

	if ( $compressedDataDirBackup eq "TRUE" ) {

		#Set up extract object
		my $ae = Archive::Extract->new( archive => $dataDirBackupLocation );

		print "Extracting $dataDirBackupLocation. Please wait...\n\n";
		$log->info("$subname: Extracting $dataDirBackupLocation");

		#Extract
		$ae->extract( to => escapeFilePath($dataDirPath) );
		if ( $ae->error ) {
			$log->logdie(
"Unable to extract $dataDirBackupLocation. The following error was encountered: $ae->error\n\n"
			);
		}
	}
	else {

		#Copy back last backup
		copyDirectory( $dataDirBackupLocation,
			$globalConfig->param("$lcApplication.dataDir") );
	}

	if ( $compressedInstallDirBackup eq "TRUE" ) {

		#Set up extract object
		my $ae = Archive::Extract->new( archive => $installDirBackupLocation );

		print "Extracting $installDirBackupLocation. Please wait...\n\n";
		$log->info("$subname: Extracting $installDirBackupLocation");

		#Extract
		$ae->extract( to => escapeFilePath($installDirPath) );
		if ( $ae->error ) {
			$log->logdie(
"Unable to extract $installDirBackupLocation. The following error was encountered: $ae->error\n\n"
			);
		}
	}
	else {

		#Copy back last backup
		copyDirectory( $installDirBackupLocation,
			$globalConfig->param("$lcApplication.installDir") );
	}

	print
"$application has now been restored successfully. Please restore your database and then start up the services manually.\n\n";
	print
"Please note that the backup has been copied back into place, therefore subsequent restores are still possible. Please press enter to return to the menu...\n";
	$input = <STDIN>;
}

########################################
#setCustomCrowdContext                 #
########################################
sub setCustomCrowdContext {
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	$log->debug("$subname: Setting custom Crowd context");
	if ( $globalConfig->param("crowd.appContext") eq "/crowd" ) {

		#do nothing, as no custom context is required, this is the default
		return;
	}
	else {
		backupDirectoryAndChown(
			escapeFilePath(
				$globalConfig->param("crowd.installDir")
				  . "/apache-tomcat/webapps/ROOT"
			),
			$globalConfig->param("crowd.osUser")
		);

		updateLineInFile(
			escapeFilePath(
				$globalConfig->param("crowd.installDir") . "/build.properties"
			),
			"crowd.url",
			"crowd.url="
			  . "crowd.url=http://localhost:"
			  . $globalConfig->param("crowd.connectorPort")
			  . getConfigItem( "crowd.appContext", $globalConfig ),
			""
		);

		system( "cd "
			  . escapeFilePath( $globalConfig->param("crowd.installDir") )
			  . " && "
			  . $globalConfig->param("crowd.installDir")
			  . "/build.sh" );
		if ( $? == -1 ) {
			$log->logdie(
"Crowd: unable to run the build script to complete the custom context. $!\n"
			);
		}

		updateLineInFile(
			escapeFilePath(
				$globalConfig->param("crowd.installDir")
				  . "/apache-tomcat/conf/server.xml"
			),
".*.*(appBase|autoDeploy|name|unpackWARs).*(appBase|autoDeploy|name|unpackWARs).*(appBase|autoDeploy|name|unpackWARs).*.*(appBase|autoDeploy|name|unpackWARs).*",
'     <Host appBase="webapps" autoDeploy="true" name="localhost" unpackWARs="true">'
			  . "\n"
			  . '           <Context path="'
			  . getConfigItem( "crowd.appContext", $globalConfig )
			  . '" docBase="../../crowd-webapp" debug="0">' . "\n"
			  . '                 <Manager pathname="'
			  . getConfigItem( "crowd.appContext", $globalConfig ) . '" />'
			  . "\n"
			  . '           </Context>' . "\n"
			  . '     </Host>' . "\n",
			""
		);
		moveFile(
			escapeFilePath(
				$globalConfig->param("crowd.installDir")
				  . "/apache-tomcat/conf/Catalina/localhost/crowd.xml"
			),
			escapeFilePath(
				$globalConfig->param("crowd.installDir")
				  . "/apache-tomcat/conf/Catalina/localhost/crowdbak.bak"
			)
		);
	}
}

########################################
#startService                          #
#When using this function you need to  #
#cater for returns of:                 #
#1. SUCCESS                            #
#2. FAIL                               #
#3. WARN                               #
########################################
sub startService {
	my @PIDs;
	my $line;
	my $i;
	my $application;
	my $lcApplication;
	my @pidList;
	my $grep1stParam;
	my $grep2ndParam;
	my $serviceName;
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");
	$application   = $_[0];
	$lcApplication = lc($application);
	$grep1stParam  = $_[1];
	$grep2ndParam  = $_[2];
	dumpSingleVarToLog( "$subname" . "_application",  $application );
	dumpSingleVarToLog( "$subname" . "_grep1stParam", $grep1stParam );
	dumpSingleVarToLog( "$subname" . "_grep2ndParam", $grep2ndParam );

	#first make sure service is not already started
	@pidList = getPIDList( $grep1stParam, $grep2ndParam );

	$serviceName = $lcApplication;

	if ( @pidList > 0 ) {

		#Service is started we need to stop it
		$log->info("$subname: $application is already running.");
		print "The $application service is already running.\n\n";
		return "SUCCESS";
	}

	#then start the service
	system( "service " . $serviceName . " start" );

	@pidList = getPIDList( $grep1stParam, $grep2ndParam );
	if ( @pidList == 1 ) {

		#service started successfully
		$log->info(
"$subname: $application started successfully. 1 process now running."
		);
		print
		  "\n\n The $application service has been started successfully.\n\n";
		return "SUCCESS";
	}
	elsif ( @pidList == 0 ) {

		#service did not start successfully
		$log->warn(
"$subname: $application did not start successfully. No such process running."
		);
		print "\n\n The $application service did not start correctly.\n\n";
		return "WARN";
	}
	elsif ( @pidList > 0 ) {

		#duplicate processes running
		$log->warn("$subname: $application has duplicate processes running.");
		print
"The $application service has spawned duplicate processes. This should not happen and should be investigated.\n\n";
		return "WARN";
	}
}

########################################
#stopService                           #
#When using this function you need to  #
#cater for returns of:                 #
#1. SUCCESS                            #
#2. FAIL                               #
########################################
sub stopService {
	my @PIDs;
	my $line;
	my $i;
	my $application;
	my $lcApplication;
	my @pidList;
	my $processID;
	my $grep1stParam;
	my $grep2ndParam;
	my $LOOP  = 1;
	my $LOOP2 = 1;
	my $LOOP3 = 1;
	my $input;
	my $serviceName;
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");
	$application   = $_[0];
	$lcApplication = lc($application);
	$grep1stParam  = $_[1];
	$grep2ndParam  = $_[2];
	dumpSingleVarToLog( "$subname" . "_application",  $application );
	dumpSingleVarToLog( "$subname" . "_grep1stParam", $grep1stParam );
	dumpSingleVarToLog( "$subname" . "_grep2ndParam", $grep2ndParam );
	$serviceName = $lcApplication;

	while ( $LOOP == 1 ) {

		#first make sure the service is actually running
		@pidList = getPIDList( $grep1stParam, $grep2ndParam );

		if ( @pidList == 0 ) {

			#Service is not running... no need to stop it
			$log->debug(
"$subname: $application is not running. There is no need to stop."
			);
			print "The $application service is already stopped.\n\n";
			$LOOP = 0;
			return "SUCCESS";
		}
		elsif ( @pidList == 1 ) {

			#attempt to stop the service
			print "Attempting to stop the $application service.\n\n";
			$log->info(
				"$subname: Attempting to stop the $application service.");
			system( "service " . $serviceName . " stop --disable-kill" );
			print
"Stop command completed successfully. Sleeping for 20 seconds before testing to ensure process has died.\n\n";
			$log->info(
				"$subname: Stop command completed. Sleeing for 20 seconds.");
			sleep 20;

			#Testing to see if the process stop has succeeded
			@pidList = getPIDList( $grep1stParam, $grep2ndParam );
			if ( @pidList == 0 ) {

				#Stop completed successfully
				print "The $application service was stopped succesfully.\n\n";
				$log->info(
					"$subname: $application service stopped succesfully.");
				$LOOP = 0;
				return "SUCCESS";
			}
			elsif ( @pidList == 1 ) {

				#Process is still running sleep for another 30 seconds
				print
"The process still appears to be running... Sleeping for another 30 seconds after which you can opt to kill the process.\n\n";
				$log->info(
"$subname: $application Process still running. Sleeing for another 30 seconds."
				);
				sleep 30;

			   #Testing again and if still running see what the user wants to do
				@pidList = getPIDList( $grep1stParam, $grep2ndParam );
				if ( @pidList == 0 ) {

					#Stop completed successfully
					print
					  "The $application service was stopped succesfully.\n\n";
					$log->info(
						"$subname: $application service stopped succesfully.");
					$LOOP = 0;
					return "SUCCESS";
				}
				elsif ( @pidList == 1 ) {

					#Process is still running try again or kill?
					$log->info(
"$subname: $application process still running. Offering option to try again or kill."
					);

					print
"The process still appears to be running... Would you like to try again or kill the process? (try/kill) [kill]: ";
					$LOOP2 = 1
					  ; #Resetting the loop in case we have deliberately broken out.
					while ( $LOOP2 == 1 ) {

						$input = <STDIN>;
						print "\n";
						chomp $input;

						if (   ( lc $input ) eq "kill"
							|| ( lc $input ) eq "k"
							|| ( lc $input ) eq "" )
						{

							#Kill The Process
							if ( $pidList[0] =~
								/^([A-Za-z0-9]*)\s*([0-9]*)\s*(.*)$/ )
							{
								$processID = $2;

								system("kill -9 $processID");
								sleep 1;    #sleep for a second just for safety.

								@pidList =
								  getPIDList( $grep1stParam, $grep2ndParam );
								if ( @pidList == 0 ) {

									#Stop completed successfully
									print
"The $application service was killed succesfully.\n\n";
									$log->info(
"$subname: $application service killed succesfully."
									);
									$LOOP = 0;
									return "SUCCESS";
								}
								elsif ( @pidList == 1 ) {
									print
"The $application service could not be killed.\n\n";
									$log->info(
"$subname: $application service could not be killed."
									);
									return "FAIL";
								}
							}
						}
						elsif (( lc $input ) eq "try"
							|| ( lc $input ) eq "t" )
						{
							$LOOP2 = 0
							  ; #break this inner loop to return to the outer loop
						}
						else {
							$log->info(
"$subname: Input not recognised, asking user for input again."
							);
							print "Your input '" . $input
							  . "'was not recognised. Please try again and write 'try' or 'kill'.\n";
						}
					}
				}
			}
		}
		elsif ( @pidList > 1 ) {

			#Multiple matching processes running
			$log->info(
"$subname: Multiple $application process running. Offering option to kill them manually."
			);

			print
"There are duplicate processes running for $application, these will have to be killed manually. Please press enter to continue. ";
			$input = <STDIN>;
			print "\n";

			while ( $LOOP3 == 1 ) {

				print
"The following duplicate processes are running for $application:\n\n ";
				print "UID        PID  PPID  C STIME TTY          TIME CMD\n";

				foreach (@pidList) {
					$log->info("$subname: Duplicate process --> $_");
					print "$_" . "\n";
				}
				print "\n\n";

				print
"Please enter the process ID you would like to kill (one at a time): ";
				$input = <STDIN>;
				print "\n";
				chomp $input;

				#Kill The Process

				system("kill -9 $input");
				sleep 1;    #sleep for a second just for safety.

				@pidList = getPIDList( $grep1stParam, $grep2ndParam );
				if ( @pidList == 0 ) {

					#Stop completed successfully
					print
					  "The $application services were killed succesfully.\n\n";
					$log->info(
"$subname: $application services were killed succesfully."
					);
					$LOOP  = 0;
					$LOOP3 = 0;
					return "SUCCESS";
				}
				elsif ( @pidList > 0 ) {
					$LOOP3 =
					  1;  #continue providing option to kill remaining processes
				}
			}
		}
	}
}

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
#updateCATALINAOPTS                    #
########################################
sub updateCatalinaOpts {
	my $inputFile;    #Must Be Absolute Path
	my $catalinaOpts;
	my $searchFor;
	my $baseReferenceLine;
	my $referenceVariable;
	my @data;
	my $application;
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	$application       = $_[0];
	$inputFile         = $_[1];
	$referenceVariable = $_[2];
	$catalinaOpts      = $_[3];

#As none of the applications setenv.sh files currently have CATALINA_OPTS we need to define
#a line that will always exist for each application to insert CATALINA_OPTS after

	if ( $application eq "Confluence" ) {
		$baseReferenceLine = "JAVA_OPTS=";
	}
	elsif ( $application eq "JIRA" ) {
		$baseReferenceLine = "JVM_REQUIRED_ARGS=";
	}
	elsif ( $application eq "Bamboo" ) {
		$baseReferenceLine = "JVM_REQUIRED_ARGS=";
	}
	elsif ( $application eq "Crowd" ) {
		$baseReferenceLine = "JAVA_OPTS=";
	}
	elsif ( $application eq "Stash" ) {
		$baseReferenceLine = "JVM_REQUIRED_ARGS=";
	}

#If no catalinaOpts parameters defined we get an undefined variable. This accounts for that.
	if ( !defined $catalinaOpts ) {
		$catalinaOpts = "";
	}

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_inputFile",    $inputFile );
	dumpSingleVarToLog( "$subname" . "_catalinaOpts", $catalinaOpts );

	#Try to open the provided file
	open( my $inputFileHandle, '<', $inputFile )
	  or $log->logdie("Unable to open file: $inputFile");

	# read file into an array
	@data = <$inputFileHandle>;

	close($inputFileHandle);

	$searchFor = $referenceVariable;

	#Search for the provided string in the file array
	my ($index1) = grep { $data[$_] =~ /^$searchFor.*/ } 0 .. $#data;

	if ( !defined($index1) ) {
		$log->debug("$subname: $searchFor not found. Adding it in.");
		my ($index0) =
		  grep { $data[$_] =~ /^$baseReferenceLine.*/ } 0 .. $#data;

		splice( @data, $index0 + 1, 0,
			    'CATALINA_OPTS="$CATALINA_OPTS $ATLASMGR_CATALINA_OPTS"'
			  . "\nexport CATALINA_OPTS\n" );
		($index1) = grep { $data[$_] =~ /^$searchFor.*/ } 0 .. $#data;
	}

#See how many times ATLASMGR_CATALINA_OPTS occurs in file, this will be in the existing
#CATALINA_OPTS parameter as a variable (if it exists).
#If it doesn't exist this splits up the string so that we can insert it as a new variable
	my $count = grep( /.*ATLASMGR_CATALINA_OPTS.*/, $data[$index1] );
	if ( $count == 0 ) {
		$log->debug(
"$subname: ATLASMGR_CATALINA_OPTS does not yet exist, splitting string to insert it."
		);
		if ( $data[$index1] =~ /(.*?)\"(.*?)\"(.*?)/ ) {
			my $result1 = $1;
			my $result2 = $2;
			my $result3 = $3;

			if ( substr( $result2, -1, 1 ) eq " " ) {
				$data[$index1] =
				    $result1 . '"' 
				  . $result2
				  . '$ATLASMGR_CATALINA_OPTS "'
				  . $result3 . "\n";
			}
			else {
				$data[$index1] =
				    $result1 . '"' 
				  . $result2
				  . ' $ATLASMGR_CATALINA_OPTS"'
				  . $result3 . "\n";
			}
		}
	}

#Search for the definition of the variable ATLASMGR_CATALINA_OPTS which can be used to add
#additional parameters to the main JAVA_OPTS variable
	$searchFor = "ATLASMGR_CATALINA_OPTS=";
	my ($index2) = grep { $data[$_] =~ /^$searchFor.*/ } 0 .. $#data;

#If no result is found insert a new line before the line found above which contains the CATALINA_OPTS variable
	my ($index3) = grep { $data[$_] =~ /^$referenceVariable.*/ } 0 .. $#data;
	if ( !defined($index2) ) {
		$log->debug(
			"$subname: ATLASMGR_CATALINA_OPTS= not found. Adding it in.");

		splice( @data, $index3, 0,
			"ATLASMGR_CATALINA_OPTS=\"" . $catalinaOpts . "\"\n" );
	}

	#Else update the line to have the new parameters that have been specified
	else {
		$log->debug(
"$subname: ATLASMGR_CATALINA_OPTS= exists, adding new javaOpts parameters."
		);
		$data[$index2] = "ATLASMGR_CATALINA_OPTS=\"" . $catalinaOpts . "\"\n";
	}

	#Try to open file, output the lines that are in memory and close
	open( my $outputFileHandle, '>', "$inputFile" )
	  or $log->logdie("Unable to open file $inputFile $!");
	print $outputFileHandle @data;
	close $outputFileHandle;

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

	$log->debug("BEGIN: $subname");

	$inputFile    = $_[0];
	$referenceVar = $_[1];
	$newValue     = $_[2];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_inputFile",    $inputFile );
	dumpSingleVarToLog( "$subname" . "_referenceVar", $referenceVar );
	dumpSingleVarToLog( "$subname" . "_newValue",     $newValue );

	#Try to open the provided file
	open( my $inputFileHandle, '<', $inputFile )
	  or $log->logdie("Unable to open file: $inputFile");

	# read file into an array
	@data = <$inputFileHandle>;

	close($inputFileHandle);

	#Search for the definition of the provided variable
	$searchFor = "$referenceVar=";
	my ($index2) = grep { $data[$_] =~ /^$searchFor.*/ } 0 .. $#data;

#If no result is found insert a new line before the line found above which contains the JAVA_OPTS variable
	if ( !defined($index2) ) {
		$log->debug("$subname: $referenceVar= not found. Adding it in.");

		push( @data, $referenceVar . "=\"" . $newValue . "\"\n" );
	}

	#Else update the line to have the new parameters that have been specified
	else {
		$log->debug(
"$subname: $referenceVar= exists, updating to have new value: $newValue."
		);
		$data[$index2] = $referenceVar . "=\"" . $newValue . "\"\n";
	}

	#Try to open file, output the lines that are in memory and close
	open( my $outputFileHandle, '>', "$inputFile" )
	  or $log->logdie("Unable to open file $inputFile $!");
	print $outputFileHandle @data;
	close $outputFileHandle;
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

	$log->debug("BEGIN: $subname");

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
	open( my $inputFileHandle, '<', $inputFile )
	  or $log->logdie("Unable to open file: $inputFile");

	# read file into an array
	@data = <$inputFileHandle>;

	close($inputFileHandle);

	$searchFor = $referenceVariable;

	#Search for the provided string in the file array
	my ($index1) = grep { $data[$_] =~ /^$searchFor.*/ } 0 .. $#data;

	my $count = grep( /.*$referenceParameter.*/, $data[$index1] );
	dumpSingleVarToLog( "$subname" . "_count",          $count );
	dumpSingleVarToLog( "$subname" . " ORIGINAL LINE=", $data[$index1] );

	if ( $count == 1 ) {
		$log->debug("$subname: Splitting string to update the memory value.");
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
		$log->debug(
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

	$log->debug(
		"$subname: Value updated, outputting new line to file $inputFile.");

	#Try to open file, output the lines that are in memory and close
	open( my $outputFileHandle, '>', "$inputFile" )
	  or $log->logdie("Unable to open file $inputFile $!");
	print $outputFileHandle @data;
	close $outputFileHandle;
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

	$log->debug("BEGIN: $subname");

	$inputFile         = $_[0];
	$referenceVariable = $_[1];
	$javaOpts          = $_[2];

#If no javaOpts parameters defined we get an undefined variable. This accounts for that.
	if ( !defined $javaOpts ) {
		$javaOpts = "";
	}

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_inputFile", $inputFile );
	dumpSingleVarToLog( "$subname" . "_javaOpts",  $javaOpts );

	#Try to open the provided file
	open( my $inputFileHandle, '<', $inputFile )
	  or $log->logdie("Unable to open file: $inputFile");

	# read file into an array
	@data = <$inputFileHandle>;

	close($inputFileHandle);

	$searchFor = $referenceVariable;

	#Search for the provided string in the file array
	my ($index1) = grep { $data[$_] =~ /^$searchFor.*/ } 0 .. $#data;

#See how many times ATLASMGR_JAVA_OPTS occurs in file, this will be in the existing
#JAVA_OPTS parameter as a variable.
#If it doesn't exist this splits up the string so that we can insert it as a new variable
	my $count = grep( /.*ATLASMGR_JAVA_OPTS.*/, $data[$index1] );
	if ( $count == 0 ) {
		$log->debug(
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
		$log->debug("$subname: ATLASMGR_JAVA_OPTS= not found. Adding it in.");

		splice( @data, $index1, 0,
			"ATLASMGR_JAVA_OPTS=\"" . $javaOpts . "\"\n" );
	}

	#Else update the line to have the new parameters that have been specified
	else {
		$log->debug(
"$subname: ATLASMGR_JAVA_OPTS= exists, adding new javaOpts parameters."
		);
		$data[$index2] = "ATLASMGR_JAVA_OPTS=\"" . $javaOpts . "\"\n";
	}

	#Try to open file, output the lines that are in memory and close
	open( my $outputFileHandle, '>', "$inputFile" )
	  or $log->logdie("Unable to open file $inputFile $!");
	print $outputFileHandle @data;
	close $outputFileHandle;

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

	$log->debug("BEGIN: $subname");

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
		$log->debug(
"$subname: Found $searchString in $xmlFile. Setting $referenceAttribute to $attributeValue"
		);

		#Set the node to the new attribute value
		$node->set_att( $referenceAttribute => $attributeValue );
	}

	#Print the new XML tree back to the original file
	$log->debug("$subname: Writing out updated xmlFile: $xmlFile.");
	$twig->print_to_file($xmlFile);
}

########################################
#updateXMLTextValue                    #
########################################
sub updateXMLTextValue {

	my $xmlFile;    #Must Be Absolute Path
	my $searchString;
	my $attributeValue;
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	$xmlFile        = $_[0];
	$searchString   = $_[1];
	$attributeValue = $_[2];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_xmlFile",        $xmlFile );
	dumpSingleVarToLog( "$subname" . "_searchString",   $searchString );
	dumpSingleVarToLog( "$subname" . "_attributeValue", $attributeValue );

	#Set up new XML object, with "pretty" spacing (i.e. standard spacing)
	my $twig = new XML::Twig( pretty_print => 'indented' );

	#Parse the XML file
	$twig->parsefile($xmlFile);

	#Find the node we are looking for based on the provided search string
	for my $node ( $twig->findnodes($searchString) ) {
		$log->debug(
"$subname: Found $searchString in $xmlFile. Setting element to $attributeValue"
		);

		#Set the node to the new attribute value
		$node->set_text($attributeValue);
	}

	#Print the new XML tree back to the original file
	$log->debug("$subname: Writing out updated xmlFile: $xmlFile.");
	$twig->print_to_file($xmlFile);
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
	my $newLine;
	my $count   = 0;
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

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
	open( my $inputFileHandle, '<', $inputFile )
	  or $log->logdie("Unable to open file: $inputFile: $!");

	# read file into an array
	@data = <$inputFileHandle>;

	close($inputFileHandle);

	#Search for reference line
	($index1) =
	  grep { $data[$_] =~ /.*$parameterReference.*/ } 0 .. $#data;
	if ( !defined($index1) ) {
		$log->debug(
"$subname: Line with $parameterReference not found. Going to add it."
		);

#Find the number of parameters already existing to get the next number
#This is not ideal however I expect this will be deprecated soon when Bamboo moves off Jetty.
		foreach my $line (@data) {
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
		my $newLine = $variableReference . $count . "=" . $newValue . "\n";
		dumpSingleVarToLog( "$subname" . "_newLine", $newLine );
		splice( @data, $index1, 0, $newLine );

	}
	else {
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
	open( my $outputFileHandle, '>', "$inputFile" )
	  or $log->logdie("Unable to open file: $inputFile: $!");
	print $outputFileHandle @data;
	close $outputFileHandle;
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

	$log->debug("BEGIN: $subname");

	$inputFile      = $_[0];
	$lineReference  = $_[1];
	$newLine        = $_[2];
	$lineReference2 = $_[3];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_inputFile",      $inputFile );
	dumpSingleVarToLog( "$subname" . "_lineReference",  $lineReference );
	dumpSingleVarToLog( "$subname" . "_newLine",        $newLine );
	dumpSingleVarToLog( "$subname" . "_lineReference2", $lineReference2 );
	open( my $inputFileHandle, '<', $inputFile )
	  or $log->logdie("Unable to open file: $inputFile: $!");

	# read file into an array
	@data = <$inputFileHandle>;

	close($inputFileHandle);

	#Search for reference line
	my ($index1) =
	  grep { $data[$_] =~ /^([\s]*)$lineReference.*/ } 0 .. $#data;

	#If you cant find the first reference try for the second reference
	if ( !defined($index1) ) {
		$log->debug("$subname: First search term $lineReference not found.");
		if ( defined($lineReference2) ) {
			$log->debug("$subname: Trying to search for $lineReference2.");
			my ($index1) =
			  grep { $data[$_] =~ /^([\s]*)$lineReference2.*/ } 0 .. $#data;
			if ( !defined($index1) ) {
				$log->logdie(
"No line containing \"$lineReference\" found in file $inputFile\n\n"
				);
			}

			#Otherwise replace the line with the new provided line
			else {
				$log->debug(
					"$subname: Replacing '$data[$index1]' with $newLine.");
				my ($spaceReturn) = $data[$index1] =~ /^(\s*)$lineReference2.*/;
				$data[$index1] = $spaceReturn . $newLine . "\n";
			}
		}
		else {
			$log->logdie(
"No line containing \"$lineReference\" found in file $inputFile\n\n"
			);
		}
	}
	else {
		$log->debug("$subname: Replacing '$data[$index1]' with $newLine.");
		my ($spaceReturn) = $data[$index1] =~ /^(\s*)$lineReference.*/;
		$data[$index1] = $spaceReturn . $newLine . "\n";
	}

	#Write out the updated file
	open( my $outputFileHandle, '>', "$inputFile" )
	  or $log->logdie("Unable to open file: $inputFile: $!");
	print $outputFileHandle @data;
	close $outputFileHandle;
}

########################################
#updateSeraphConfig                    #
########################################
sub updateSeraphConfig {
	my $inputFile;    #Must Be Absolute Path
	my $newLine;
	my $lineReference;
	my $searchFor;
	my $lineReference2;
	my $leadingSpace;
	my $line;
	my $trailingSpace;
	my $application;
	my $lcApplication;
	my @data;
	my $index1;
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	$application    = $_[0];
	$inputFile      = $_[1];
	$lineReference  = $_[2];    #lineToBeUncommented
	$lineReference2 = $_[3];    #lineToBeCommentedOut

	#SuggestedExample --> ^(.*)<!--\s*?(.*)(\s*?)-->.*$
	#SuggestedExample2 --> ^(\s*?)(.*ConfluenceAuthenticator.*)(\s*?)$

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_application",    $application );
	dumpSingleVarToLog( "$subname" . "_inputFile",      $inputFile );
	dumpSingleVarToLog( "$subname" . "_lineReference",  $lineReference );
	dumpSingleVarToLog( "$subname" . "_lineReference2", $lineReference2 );

	$lcApplication = lc($application);
	open( my $inputFileHandle, '<', $inputFile )
	  or $log->logdie("Unable to open file: $inputFile: $!");

	# read file into an array
	@data = <$inputFileHandle>;

	close($inputFileHandle);

	#Remove windows newlines to get around Bamboo config file funnies
	s/\r\n/\n/g for (@data);

	#Search for reference line
	if ( $lcApplication eq "confluence" || $lcApplication eq "bamboo" ) {
		my ($index3) =
		  grep { $data[$_] =~ /^(.*)<!--\s*?(.*$lineReference.*)(\s*?)-->.*/ }
		  0 .. $#data;
		$index1 = $index3;
	}
	elsif ( $lcApplication eq "jira" ) {
		my ($index3) =
		  grep { $data[$_] =~ /^(.*)\s*?(.*$lineReference.*)(\s*?).*/ }
		  0 .. $#data;

		$index1 = $index3;
	}

	my ($index2) =
	  grep { $data[$_] =~ /^(\s*?)(.*$lineReference2.*)(\s*?)/ } 0 .. $#data;

 #If you cant find the first reference and the second reference output an error.
	if ( !defined($index1) || !defined($index2) ) {
		$log->debug(
"$subname: Unable to find both lines to update Seraph config, you may need to update these manually."
		);
		$log->debug(
			"$subname: SeraphLine1Index: $index1, SeraphLine2Index: $index2.");
		print
"We were unable to find both the lines expected to be able to update the Seraph Config for SSO please make sure you check this file manually.\n";
		print
		  "The file is located at: $inputFile. Please press enter to continue.";
		my $input = <STDIN>;

	}
	else {

		#do Line 2 first as it may be further down
		$log->debug("$subname: CommentingOut '$data[$index2]'.");
		if ( $data[$index2] =~ /^(\s*?)(<.*$lineReference2.*)(\s*?)/ ) {
			$leadingSpace  = $1;
			$line          = $2;
			$trailingSpace = $3;
			chomp $trailingSpace;
		}
		$data[$index2] =
		  $leadingSpace . "<!-- " . $line . " -->" . $trailingSpace . "\n";

		$log->debug("$subname: Uncommenting '$data[$index1]'.");
		if ( $lcApplication eq "confluence" || $lcApplication eq "bamboo" ) {
			if ( $data[$index1] =~
				/^(.*)<!--\s*?(.*$lineReference.*)(\s*?)-->.*/ )
			{
				$leadingSpace  = $1;
				$line          = $2;
				$trailingSpace = $3;
				chomp $trailingSpace;
			}
			$data[$index1] = $leadingSpace . $line . $trailingSpace . "\n";
		}
		elsif ( $lcApplication eq "jira" ) {
			splice( @data, $index1 + 1, 1 );
			splice( @data, $index1 - 1, 1 );
		}
	}

	#Write out the updated file
	open( my $outputFileHandle, '>', "$inputFile" )
	  or $log->logdie("Unable to open file: $inputFile: $!");
	print $outputFileHandle @data;
	close $outputFileHandle;
}

########################################
#Uninstall Generic                     #
########################################
sub uninstallGeneric {
	my $application;
	my $initdFile;
	my $input;
	my $subname = ( caller(0) )[3];
	my $lcApplication;
	my $processReturnCode;

	$log->debug("BEGIN: $subname");

	$application   = $_[0];
	$lcApplication = lc($application);
	$initdFile     = "/etc/init.d/$lcApplication";

	dumpSingleVarToLog( "$subname" . "_application", $application );

	print
"This will uninstall $application. This will delete the installation directory AND provide the option to delete the data directory.\n";
	print
"You have been warned, proceed only if you have backed up your installation as there is no turning back.\n\n";

	$input = getBooleanInput("Do you really want to continue? yes/no [no]: ");
	print "\n";
	if ( $input eq "yes" ) {
		$log->info("$subname: User selected to uninstall $application");

		$log->info("$subname: Stopping existing $application service...");
		print "Stopping the existing $application service please wait...\n\n";
		$processReturnCode = stopService(
			$application,
			"\""
			  . $globalConfig->param(
				$lcApplication . ".processSearchParameter1"
			  )
			  . "\"",
			"\""
			  . $globalConfig->param(
				$lcApplication . ".processSearchParameter2"
			  )
			  . "\""
		);

		if ( $processReturnCode eq "FAIL" ) {
			print
"We were unable to stop the $application process. Therefore you will need to manually kill the running process following the uninstall.\n\n";
			$log->logwarn(
"$subname: We were unable to stop the $application process. Therefore you will need to manually kill the running process following the uninstall."
			);
		}

		#Remove Service
		print "Disabling service...\n\n";
		$log->info("$subname: Disabling $application service");
		manageService( $application, "UNINSTALL" );

		#remove init.d file
		print "Removing init.d file\n\n";
		$log->info( "$subname: Removing $application" . "'s init.d file" );
		unlink $initdFile or warn "Could not unlink $initdFile: $!";

		#Remove install dir
		print "Removing installation directory...\n\n";
		$log->info(
			"$subname: Removing "
			  . escapeFilePath(
				$globalConfig->param("$lcApplication.installDir")
			  )
		);
		if (
			-d escapeFilePath(
				$globalConfig->param("$lcApplication.installDir") ) )
		{
			rmtree(
				[
					escapeFilePath(
						$globalConfig->param("$lcApplication.installDir")
					)
				]
			);
		}
		else {
			$log->warn(
				"$subname: Unable to remove "
				  . escapeFilePath(
					$globalConfig->param("$lcApplication.installDir")
				  )
				  . ". Directory does not exist."
			);
			print
"Could not find configured install directory... possibly not installed?\n\n";
		}

		#Check if you REALLY want to remove data directory
		$input = getBooleanInput(
"We will now remove the data directory ($application home directory). Are you REALLY REALLY REALLY REALLY sure you want to do this? (not recommended) yes/no [no]: \n"
		);
		print "\n";
		if ( $input eq "yes" ) {
			$log->info(
				"$subname: User selected to delete "
				  . escapeFilePath(
					$globalConfig->param("$lcApplication.dataDir")
				  )
				  . ". Deleting."
			);
			rmtree(
				[
					escapeFilePath(
						$globalConfig->param("$lcApplication.dataDir")
					)
				]
			);
		}
		else {
			$log->info(
"$subname: User opted to keep the $application data directory at "
				  . escapeFilePath(
					$globalConfig->param("$lcApplication.dataDir")
				  )
				  . "."
			);
			print
"The data directory has not been deleted and is still available at "
			  . escapeFilePath( $globalConfig->param("$lcApplication.dataDir") )
			  . ".\n\n";
		}

		#Update config to null out the application config
		$log->info(
			"$subname: Nulling out the installed version of $application.");
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
#UpgradeGeneric                        #
########################################
sub upgradeGeneric {
	my $input;
	my $mode;
	my $version;
	my $application;
	my $lcApplication;
	my @downloadDetails;
	my $downloadArchivesUrl;
	my @requiredConfigItems;
	my $archiveLocation;
	my $versionSupported;
	my $osUser;
	my $processReturnCode;
	my $VERSIONLOOP = 1;
	my @uidGid;
	my $serverPortAvailCode;
	my $connectorPortAvailCode;
	my @tomcatParameterNull;
	my @webappParameterNull;
	my $removeDownloadedDataAnswer;
	my $tomcatDir;
	my $webappDir;
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	$application         = $_[0];
	$downloadArchivesUrl = $_[1];
	@requiredConfigItems = @{ $_[2] };

	$lcApplication = lc($application);

#Iterate through required config items, if any are missing force an update of configuration
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

		$input = getBooleanInput(
"Would you like to review the $application config before upgrading? Yes/No [no]: "
		);
		print "\n";
		if ( $input eq "yes" ) {
			$log->info(
				"$subname: User opted to update config prior to installation."
			);
			generateApplicationConfig( $application, "UPDATE", $globalConfig );
			$log->info("Writing out config file to disk.");
			$globalConfig->write($configFile);
			loadSuiteConfig();
		}
	}

  #Set up list of config items that are requred for this specific upgrade to run
	@requiredConfigItems = ("$lcApplication.installedVersion");

#Iterate through required config items, if an are missing force an update of configuration
	if ( checkRequiredConfigItems(@requiredConfigItems) eq "FAIL" ) {
		genConfigItem(
			"UPDATE",
			$globalConfig,
			"$lcApplication.installedVersion",
"There is no version listed in the config file for the currently installed version of $application . Please enter the version of $application that is CURRENTLY installed.",
			"",
			"",
			""
		);
		$log->info("Writing out config file to disk.");
		$globalConfig->write($configFile);
		loadSuiteConfig();
	}

	#set up the tomcat and webapp parameters as sometimes these can be null
	@tomcatParameterNull = $globalConfig->param("$lcApplication.tomcatDir");
	@webappParameterNull = $globalConfig->param("$lcApplication.webappDir");

	if ( $#tomcatParameterNull == -1 ) {
		$tomcatDir = "";
	}
	else {
		$tomcatDir = $globalConfig->param("$lcApplication.tomcatDir");

	}

	if ( $#webappParameterNull == -1 ) {
		$webappDir = "";
	}
	else {
		$webappDir = $globalConfig->param("$lcApplication.webappDir");

	}

	$input = getBooleanInput(
		"Would you like to upgrade to the latest version? yes/no [yes]: ");
	print "\n";
	if ( $input eq "default" || $input eq "yes" ) {
		$log->info(
"$subname: User opted to upgrade to the latest version of $application"
		);
		$mode = "LATEST";
	}
	else {
		$log->info(
"$subname: User opted to upgrade to a specific version of $application"
		);
		$mode = "SPECIFIC";
	}

	#If a specific version is selected, ask for the version number
	if ( $mode eq "SPECIFIC" ) {
		while ( $VERSIONLOOP == 1 ) {
			print
"Please enter the version number you would like to upgrade to. i.e. 4.2.2 []: ";

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
			$ua->show_progress(0);

			#Try to get the header of the version URL to ensure it exists
			if ( head( $downloadDetails[0] ) ) {
				$log->info(
"$subname: User selected to upgrade to version $version of $application"
				);
				$VERSIONLOOP = 0;
				print "$application version $version found. Continuing...\n\n";
			}
			else {
				$log->warn(
"$subname: User selected to upgrade to version $version of $application. No such version exists, asking for input again."
				);
				print
"No such version of $application exists. Please visit $downloadArchivesUrl and pick a valid version number to upgrade to and try again.\n\n";
			}
		}
	}

	#Download the latest version
	if ( $mode eq "LATEST" ) {
		print
"Checking to ensure the latest version is newer than the installed version. Please wait...\n\n";
		my $versionSupported = compareTwoVersions(
			$globalConfig->param("$lcApplication.installedVersion"),
			$latestVersions{"$application"}->{"version"}
		);
		if ( $versionSupported eq "GREATER" ) {
			$log->logdie( "The version of $application to be downloaded ("
				  . $latestVersions{"$application"}->{"version"}
				  . ") is older than the currently installed version ("
				  . $globalConfig->param("$lcApplication.installedVersion")
				  . "). Downgrading is not supported and this script will now exit.\n\n"
			);
		}
		else {
			print
"Latest version is newer than installed version. Continuing...\n\n";
		}

	}
	elsif ( $mode eq "SPECIFIC" && ( $enableEAPDownloads != 1 ) ) {
		my $versionSupported = compareTwoVersions(
			$globalConfig->param("$lcApplication.installedVersion"), $version );
		if ( $versionSupported eq "GREATER" ) {
			$log->logdie( "The version of $application to be downloaded (" 
				  . $version
				  . ") is older than the currently installed version ("
				  . $globalConfig->param("$lcApplication.installedVersion")
				  . "). Downgrading is not supported and this script will now exit.\n\n"
			);
		}
	}

	#Get the user the application will run as
	$osUser = $globalConfig->param("$lcApplication.osUser");

	#Check the user exists or create if not
	createOSUser( $osUser, $application );

	#Check if user wants to remove the downloaded archive
	$removeDownloadedDataAnswer = getBooleanInput(
"Do you wish to delete the downloaded archive after the upgrade is complete? [no]: "
	);
	print "\n";

	print
"We now have enough information to complete the upgrade. As part of the upgrade this script will only backup your application and data directories.\n"
	  . "It is imperative that you take a backup of your database in case the upgrade fails. You should do so now. If you attempt a rollback with this script, you must still MANUALLY\n"
	  . "restore your database. This script DOES NOT BACKUP OR RESTORE YOUR DATABASE!!!\n\n";

	print
"When you are ready to proceed with the upgrade press enter (this will stop the existing $application services). If you wish to cancel the upgrade please type 'q' and press return. ";
	$input = <STDIN>;
	print "\n\n";

	chomp($input);
	if ( lc($input) eq "q" ) {

		#Bail out and cancel the install.
		print "Upgrade has been cancelled, this script will now terminate.\n\n";
		$input = <STDIN>;
		print "\n\n";
		exit 0;
	}

	#Download the latest version
	if ( $mode eq "LATEST" ) {
		$log->info("$subname: Downloading latest version of $application");
		@downloadDetails =
		  downloadAtlassianInstaller( $mode, $application, "", $globalArch );
		$version = $downloadDetails[1];
	}

	#Download a specific version
	else {
		$log->info("$subname: Downloading version $version of $application");
		@downloadDetails =
		  downloadAtlassianInstaller( $mode, $application, $version,
			$globalArch );
	}

	#Stop the existing service
	$log->info("$subname: Stopping existing $application service...");
	$processReturnCode = stopService(
		$application,
		"\""
		  . $globalConfig->param( $lcApplication . ".processSearchParameter1" )
		  . "\"",
		"\""
		  . $globalConfig->param( $lcApplication . ".processSearchParameter2" )
		  . "\""
	);

	if ( $processReturnCode eq "FAIL" ) {
		print
"We were unable to stop the $application process therefore the upgrade cannot go ahead, please try stopping manually and trying again.\n\n";
		$log->logdie(
"$subname: We were unable to stop the process therefore the upgrade for $application cannot succeed."
		);
	}

	#Backup the existing install
	backupApplication($application);

	#Extract the download and move into place
	$log->info("$subname: Extracting $downloadDetails[2]...");
	extractAndMoveFile( $downloadDetails[2],
		escapeFilePath( $globalConfig->param("$lcApplication.installDir") ),
		$osUser, "UPGRADE" );

	#Remove the download if user opted to do so
	if ( $removeDownloadedDataAnswer eq "yes" ) {
		$log->info("$subname: User opted to delete downloaded installer.");
		unlink $downloadDetails[2]
		  or warn "Could not delete " . $downloadDetails[2] . ": $!";
	}

	#Update config to reflect new version that is installed
	$log->debug("$subname: Writing new installed version to the config file.");
	$globalConfig->param( "$lcApplication.installedVersion", $version );
	$log->info("Writing out config file to disk.");
	$globalConfig->write($configFile);
	loadSuiteConfig();

#If MySQL is the Database, Atlassian apps do not come with the driver so copy it
	if ( $globalConfig->param("general.targetDBType") eq "MySQL" ) {
		$log->info(
"$subname: Copying MySQL JDBC connector to $application install directory."
		);
		if ( $tomcatDir eq "" ) {
			createAndChownDirectory(
				escapeFilePath(
					$globalConfig->param("$lcApplication.installDir")
				  )
				  . "/lib/",
				$osUser
			);
		}
		else {
			createAndChownDirectory(
				escapeFilePath(
					$globalConfig->param("$lcApplication.installDir")
				  )
				  . $tomcatDir . "/lib/",
				$osUser
			);
		}

		print
"Database is configured as MySQL, copying the JDBC connector to $application install.\n\n";
		if ( $tomcatDir eq "" ) {
			copyFile(
				$globalConfig->param("general.dbJDBCJar"),
				escapeFilePath(
					$globalConfig->param("$lcApplication.installDir")
				  )
				  . "/lib/"
			);
		}
		else {
			copyFile(
				$globalConfig->param("general.dbJDBCJar"),
				escapeFilePath(
					$globalConfig->param("$lcApplication.installDir")
				  )
				  . $tomcatDir . "/lib/"
			);
		}

		#Chown the files again
		if ( $tomcatDir eq "" ) {
			$log->debug(
				"$subname: Chowning "
				  . escapeFilePath(
					$globalConfig->param("$lcApplication.installDir")
				  )
				  . "/lib/"
				  . " to $osUser following MySQL JDBC install."
			);
			chownRecursive(
				$osUser,
				escapeFilePath(
					$globalConfig->param("$lcApplication.installDir")
				  )
				  . "/lib/"
			);
		}
		else {
			$log->debug(
				"$subname: Chowning "
				  . escapeFilePath(
					$globalConfig->param("$lcApplication.installDir")
				  )
				  . $tomcatDir . "/lib/"
				  . " to $osUser following MySQL JDBC install."
			);
			chownRecursive(
				$osUser,
				escapeFilePath(
					$globalConfig->param("$lcApplication.installDir")
				  )
				  . $tomcatDir . "/lib/"
			);
		}
	}

#Force a re-chowning of the application data directory in case the service user has changed
	$log->debug(
		"$subname: Checking for and chowning $application home directory.");
	print "Checking if data directory exists and re-chowning it...\n\n";
	createAndChownDirectory(
		escapeFilePath( $globalConfig->param("$lcApplication.dataDir") ),
		$osUser );

	#GenericUpgradeCompleted
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

#######################################################################
#END SUPPORTING FUNCTIONS                                             #
#######################################################################

#######################################################################
#BEGIN BOOTSTRAP AND GUI FUNCTIONS                                    #
#######################################################################

########################################
#BootStrapper                          #
########################################
sub bootStrapper {
	my @parameterNull;
	my @proxyParameterNull;
	my @requiredConfigItems;
	my $applicationToCheck;
	my $lcApplicationToCheck;
	my $input;
	my $configChange = "FALSE";
	my $configResult;
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	#Check for supported distribution of *nix
	$distro = findDistro();

#If distro unknown die as not supported (if you receive this in error please log a bug to me)
	if ( $distro eq "unknown" ) {
		$log->logdie(
"This operating system is currently unsupported. Only Redhat (and derivatives) and Debian (and derivatives) currently supported.\n\n"
		);
	}

	#load logger file name
	my $conf = Log::Log4perl::Config::PropertyConfigurator->new();
	$conf->file("log4j.conf");
	$conf->parse();    # will die() on error

	$logFile = $conf->value("log4perl.appender.LOGFILE.filename");

	#Create working directory if it doesn't already exist
	createDirectory("$Bin/working");

	#get environment details if we are in debug mode.
	getEnvironmentDebugInfo();

	#Try to load configuration file
	loadSuiteConfig();

	#If no config found, force generation
	if ( !$globalConfig ) {
		$log->info("No config file found, forcing global config generation.");

		displayInitialConfigMenu();
	}

 #If config file exists check for required config items.
 #Useful if new functions have been added to ensure new config items are defined
	else {
		@requiredConfigItems = (
			"general.rootDataDir",  "general.rootInstallDir",
			"general.targetDBType", "general.force32Bit",
			"general.apacheProxy",  "general.compressBackups"
		);
		if ( checkRequiredConfigItems(@requiredConfigItems) eq "FAIL" ) {
			$log->info(
				"Some config items missing, kicking off config generation");
			print
"There are some global configuration items that are incomplete or missing. This is likely due to new features or new config items.\n\nThe global config manager will now run to get all items, please press return/enter to begin.\n\n";
			$input = <STDIN>;
			generateSuiteConfig();
		}

	  #Check for database setting that requires a JDBC Jar file to be downloaded
	  #to ensure this is done, we die if the parameter is not defined.
		else {
			@parameterNull = $globalConfig->param("general.dbJDBCJar");
			if (
				( $globalConfig->param("general.targetDBType") eq "MySQL" ) & (
					( $#parameterNull == -1 )
					  || $globalConfig->param("general.dbJDBCJar") eq ""
				)
			  )
			{
				print
"In order to continue you must download the JDBC JAR file for "
				  . $globalConfig->param("general.targetDBType")
				  . " attempting to do so now.\n\n";
				downloadJDBCConnector( "MySQL", $globalConfig );
			}
		}
	}

	#set up proxy configuration
	@proxyParameterNull = $globalConfig->param('general.httpNetworkProxy');
	if (
		defined( $globalConfig->param('general.httpNetworkProxy') ) &
		!( $#proxyParameterNull == -1 ) )
	{
		$log->info(
"$subname: HTTP Proxy has been defined and set up for use: $globalConfig->param('general.httpNetworkProxy')"
		);
		$ua->proxy( [ 'http', 'https' ],
			$globalConfig->param('general.httpNetworkProxy') );
	}

	#Set the architecture once on startup
	$globalArch = whichApplicationArchitecture();

	#Prepare some standard details before looking at command line parameters
	getAllLatestDownloadURLs();
	checkForAvailableUpdates();
	generateAvailableUpdatesString();

	#check for and apply any bugfixes since the last version
	checkASMPatchLevel();

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

	GetOptions(
		'help|h+'             => \$help,
		'gen-config+'         => \$gen_config,
		'install-crowd+'      => \$install_crowd,
		'install-confluence+' => \$install_confluence,
		'install-jira+'       => \$install_jira,
		'install-fisheye+'    => \$install_fisheye,
		'install-stash+'      => \$install_stash,
		'install-bamboo+'     => \$install_bamboo,
		'upgrade-crowd+'      => \$upgrade_crowd,
		'upgrade-confluence+' => \$upgrade_confluence,
		'upgrade-jira+'       => \$upgrade_jira,
		'upgrade-fisheye+'    => \$upgrade_fisheye,
		'upgrade-bamboo+'     => \$upgrade_bamboo,
		'upgrade-stash+'      => \$upgrade_stash,
		'enable-eap'          => \$enableEAPDownloads

		  #Below to be added in future versions
		  #		'tar-crowd-logs+'            => \$tar_crowd_logs,
		  #		'tar-confluence-logs+'       => \$tar_confluence_logs,
		  #		'tar-jira-logs+'             => \$tar_jira_logs,
		  #		'tar-fisheye-logs+'          => \$tar_fisheye_logs,
		  #		'tar-bamboo-logs+'           => \$tar_bamboo_logs,
		  #		'tar-stash-logs+'            => \$tar_stash_logs,
		  #		'disable-service=s'          => \$disable_service,
		  #		'enable-service=s'           => \$enable_service,
		  #		'check-service=s'            => \$check_service,
		  #		'update-sh-script+'          => \$update_sh_script,
		  #		'verify-config+'             => \$verify_config,
		  #		'silent|s+'                  => \$silent,
		  #		'debug|d+'                   => \$debug,
		  #		'unsupported|u+'             => \$unsupported,
		  #		'ignore-version-warnings|i+' => \$ignore_version_warnings,
		  #		'disable-config-checks|c+'   => \$disable_config_checks,
		  #		'verbose|v+'                 => \$verbose
	);

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

	if ( $options_count > 1 ) {
		print
"You can only specify one of the install or upgrade functions at a time. Please try again specifying only one such option.\n\n";
		$log->info(
"You can only specify one of the install or upgrade functions at a time. Terminating script."
		);
		exit 1;
	}
	elsif (
		( $options_count == 1 ) & (
			$help eq '' & $gen_config eq '' & $tar_confluence_logs eq '' &
			  $tar_jira_logs    eq '' & $tar_fisheye_logs eq '' &
			  $tar_bamboo_logs  eq '' & $tar_stash_logs   eq '' &
			  $disable_service  eq '' & $check_service    eq '' &
			  $update_sh_script eq '' & $verify_config    eq ''
		)
	  )
	{
		if ( $install_crowd eq '1' ) {
			installCrowd();
		}
		elsif ( $install_confluence == 1 ) {
			installConfluence();
		}
		elsif ( $install_jira == 1 ) {
			installJira();
		}
		elsif ( $install_fisheye == 1 ) {
			installFisheye();
		}
		elsif ( $install_bamboo == 1 ) {
			installBamboo();
		}
		elsif ( $install_stash == 1 ) {
			installStash();
		}
		elsif ( $upgrade_crowd == 1 ) {
			upgradeCrowd();
		}
		elsif ( $upgrade_confluence == 1 ) {
			upgradeConfluence();
		}
		elsif ( $upgrade_jira == 1 ) {
			upgradeJira();
		}
		elsif ( $upgrade_fisheye == 1 ) {
			upgradeFisheye();
		}
		elsif ( $upgrade_bamboo == 1 ) {
			upgradeBamboo();
		}
		elsif ( $upgrade_stash == 1 ) {
			upgradeStash();
		}
		exit 0;

#print out that you can only use one of the install or upgrade commands at a time without any other command line parameters, proceed but ignore the others
	}
	else {
		displayMainMenu();
	}
}

########################################
#Display Advanced Menu                 #
########################################
sub displayAdvancedMenu {
	my $choice;
	my $main_menu;
	my $menuOptions;
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	my $LOOP = 1;
	while ( $LOOP == 1 ) {

		# define the main menu as a multiline string
		$main_menu = generateMenuHeader( "FULL", "ASM Advanced Menu", "" );

		$menuOptions = <<'END_TXT';
      Please select from the following options:

      1) Force refresh of latest Atlassian suite application versions cache file
      2) Clear Confluence Plugin Cache
      3) Clear JIRA Plugin Cache
      4) Pre-download the latest versions of all suite products (immediately, no confirmation)
      5) Command Line Parameters Overview
      6) Force UID and GID on account creation
      7) Additional advanced documentation
      Q) Return to Main Menu

END_TXT

		# print the main menu
		system 'clear';
		print $main_menu . $menuOptions;

		# prompt for user's choice
		printf( "%s", "Please enter your selection: " );

		# capture the choice
		$choice = <STDIN>;
		dumpSingleVarToLog( "$subname" . "_choiceEntered", $choice );

		# and finally print it
		#print "You entered: ",$choice;
		if ( $choice eq "Q\n" || $choice eq "q\n" ) {
			system 'clear';
			$LOOP = 0;
		}
		elsif ( lc($choice) eq "1\n" ) {
			system 'clear';
			print generateMenuHeader( "FULL",
				"Refreshing application versions cache file. Please wait...",
				"" );
			if ( -e $latestVersionsCacheFile ) {
				print "Deleting cache file...\n\n";
				rmtree( [ escapeFilePath($latestVersionsCacheFile) ] );
				print "Refreshing the cache...\n\n";
				getAllLatestDownloadURLs();

				print
				  "Cache refresh completed. Please press enter to continue\n\n";
				my $test = <STDIN>;

			}
			else {
				print
"No cache file currently exists - proceeding with refresh...\n\n";
				getAllLatestDownloadURLs();
				print
				  "Cache refresh completed. Please press enter to continue\n\n";
				my $test = <STDIN>;
			}
		}
		elsif ( lc($choice) eq "2\n" ) {
			system 'clear';
			clearConfluencePluginCache();
			print "Please press enter to return to the menu.\n\n";
			my $test = <STDIN>;
		}
		elsif ( lc($choice) eq "3\n" ) {
			system 'clear';
			clearJIRAPluginCache();
			print "Please press enter to return to the menu.\n\n";
			my $test = <STDIN>;
		}
		elsif ( lc($choice) eq "4\n" ) {
			system 'clear';
			downloadLatestAtlassianSuite($globalArch);
		}
		elsif ( lc($choice) eq "5\n" ) {
			system 'clear';
			print generateMenuHeader( "FULL", "ASM Command Line Parameters",
				"" );
			print
"The following command line parameters are currently available for use in ASM:\n";
			print "1. Enable EAP Downloads:\n";
			print "   Command Line Parameter: '--enable-eap'\n";
			print
"   Description: can be used by app developers to skip version checks and allow installation 
                of EAP versions of Atlassian products. Please note, you can only install or upgrade to these 
                once, following that you will need to uninstall the application and 
                re-install. Atlassian does not support upgrades of EAP versions and ASM 
                follows this logic. You can attempt this but it is likely to break.\n"
			  ;

			print "\n";
			print "To return to the menu please press enter...";
			my $test = <STDIN>;
		}
		elsif ( lc($choice) eq "6\n" ) {
			system 'clear';
			print generateMenuHeader( "FULL",
				"Forcing UID/GIDs on Account Creation", "" );
			print
"If you would like to force specific UID/GIDs for new account creations please see the documentation at:\n";
			print
"http://technicalnotebook.com/wiki/display/ATLASSIANMGR/Force+UID+and+GID+on+account+creation:\n";

			print "\n";
			print "To return to the menu please press enter...";
			my $test = <STDIN>;

		}
		elsif ( lc($choice) eq "7\n" ) {
			system 'clear';
			print generateMenuHeader( "FULL",
				"Additional Advanced Documentation", "" );
			print
"There are additional advanced functions and features documented on the main wiki. Please see the documentation at:\n";
			print
"http://technicalnotebook.com/wiki/display/ATLASSIANMGR/Advanced+ASM+Usage:\n";

			print "\n";
			print "To return to the menu please press enter...";
			my $test = <STDIN>;

		}
	}
}

########################################
#Display Inital Config Menu            #
########################################
sub displayInitialConfigMenu {
	my $choice;
	my $menuText;
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	my $LOOP = 1;
	while ( $LOOP == 1 ) {

		# define the main menu as a multiline string
		$menuText = generateMenuHeader( "MINI", "Initial Config Menu", "" );
		$menuText .= <<'END_TXT';
      No configuration file has been found. Please select from the following options:

      1) Existing install: Gather configuration (one or more products already installed)
      2) New install: Generate new configuration - (no products currently installed)
      Q) Exit script

END_TXT

		# print the main menu
		system 'clear';
		print $menuText;

		# prompt for user's choice
		printf( "%s", "Please enter your selection: " );

		# capture the choice
		$choice = <STDIN>;
		dumpSingleVarToLog( "$subname" . "_choiceEntered", $choice );

		# and finally print it
		#print "You entered: ",$choice;
		if ( $choice eq "Q\n" || $choice eq "q\n" ) {
			system 'clear';
			$LOOP = 0;
		}
		elsif ( lc($choice) eq "1\n" ) {
			system 'clear';
			getExistingSuiteConfig();
			$LOOP = 0;
		}
		elsif ( lc($choice) eq "2\n" ) {
			system 'clear';
			generateSuiteConfig();
			$LOOP = 0;
		}
	}
}

########################################
#Display Install Menu                  #
########################################
sub displayInstallMenu {
	my $choice;
	my $menuText;
	my $isBambooInstalled;
	my $bambooAdditionalText = "";
	my $isCrowdInstalled;
	my $crowdAdditionalText = "";
	my $isConfluenceInstalled;
	my $confluenceAdditionalText = "";
	my $isFisheyeInstalled;
	my $fisheyeAdditionalText = "";
	my $isJiraInstalled;
	my $jiraAdditionalText = "";
	my $isStashInstalled;
	my $stashAdditionalText = "";
	my @parameterNull;
	my $input;
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	#Set up suite current install status
	@parameterNull = $globalConfig->param("bamboo.installedVersion");
	if ( ( $#parameterNull == -1 )
		|| $globalConfig->param("bamboo.installedVersion") eq "" )
	{
		$isBambooInstalled = "FALSE";
	}
	else {
		$isBambooInstalled    = "TRUE";
		$bambooAdditionalText = " (Disabled - Already Installed)";
	}

	@parameterNull = $globalConfig->param("confluence.installedVersion");
	if ( ( $#parameterNull == -1 )
		|| $globalConfig->param("confluence.installedVersion") eq "" )
	{
		$isConfluenceInstalled = "FALSE";
	}
	else {
		$isConfluenceInstalled    = "TRUE";
		$confluenceAdditionalText = " (Disabled - Already Installed)";
	}

	@parameterNull = $globalConfig->param("crowd.installedVersion");
	if ( ( $#parameterNull == -1 )
		|| $globalConfig->param("crowd.installedVersion") eq "" )
	{
		$isCrowdInstalled = "FALSE";
	}
	else {
		$isCrowdInstalled    = "TRUE";
		$crowdAdditionalText = " (Disabled - Already Installed)";
	}

	@parameterNull = $globalConfig->param("fisheye.installedVersion");
	if ( ( $#parameterNull == -1 )
		|| $globalConfig->param("fisheye.installedVersion") eq "" )
	{
		$isFisheyeInstalled = "FALSE";
	}
	else {
		$isFisheyeInstalled    = "TRUE";
		$fisheyeAdditionalText = " (Disabled - Already Installed)";
	}

	@parameterNull = $globalConfig->param("jira.installedVersion");
	if ( ( $#parameterNull == -1 )
		|| $globalConfig->param("jira.installedVersion") eq "" )
	{
		$isJiraInstalled = "FALSE";
	}
	else {
		$isJiraInstalled    = "TRUE";
		$jiraAdditionalText = " (Disabled - Already Installed)";
	}

	@parameterNull = $globalConfig->param("stash.installedVersion");
	if ( ( $#parameterNull == -1 )
		|| $globalConfig->param("stash.installedVersion") eq "" )
	{
		$isStashInstalled = "FALSE";
	}
	else {
		$isStashInstalled    = "TRUE";
		$stashAdditionalText = " (Disabled - Already Installed)";
	}

	my $LOOP = 1;
	while ( $LOOP == 1 ) {

		# define the main menu as a multiline string
		$menuText = generateMenuHeader( "FULL", "ASM Install Menu", "" );

		$menuText =
		  $menuText . "      Please select from the following options:\n\n";
		$menuText =
		  $menuText . "      1) Install Bamboo $bambooAdditionalText\n";
		$menuText =
		  $menuText . "      2) Install Confluence$confluenceAdditionalText\n";
		$menuText = $menuText . "      3) Install Crowd$crowdAdditionalText\n";
		$menuText =
		  $menuText . "      4) Install Fisheye$fisheyeAdditionalText\n";
		$menuText = $menuText . "      5) Install JIRA$jiraAdditionalText\n";
		$menuText = $menuText . "      6) Install Stash$stashAdditionalText\n";
		$menuText = $menuText . "      Q) Return to Main Menu\n";
		$menuText = $menuText . "\n";

		# print the main menu
		system 'clear';
		print $menuText;

		# prompt for user's choice
		printf( "%s", "Please enter your selection: " );

		# capture the choice
		$choice = <STDIN>;
		dumpSingleVarToLog( "$subname" . "_choiceEntered", $choice );

		# and finally print it
		#print "You entered: ",$choice;
		if ( $choice eq "Q\n" || $choice eq "q\n" ) {
			system 'clear';
			$LOOP = 0;
		}
		elsif ( lc($choice) eq "1\n" ) {
			system 'clear';
			if ( $isBambooInstalled eq "TRUE" ) {
				print
"Bamboo is already installed and therefore cannot be installed again. \nIf you believe you have received this in error, "
				  . "please edit the settings.cfg file and remove the bamboo.installedVersion setting.\n\n";
				print "Please press enter to continue...";
				$input = <STDIN>;
				print "/n";
			}
			else {
				installBamboo();
				system 'clear';
				$LOOP = 0;
				displayInstallMenu();
			}

		}
		elsif ( lc($choice) eq "2\n" ) {
			system 'clear';
			if ( $isConfluenceInstalled eq "TRUE" ) {
				print
"Confluence is already installed and therefore cannot be installed again. \nIf you believe you have received this in error, "
				  . "please edit the settings.cfg file and remove the confluence.installedVersion setting.\n\n";
				print "Please press enter to continue...";
				$input = <STDIN>;
				print "/n";
			}
			else {
				installConfluence();
				system 'clear';
				$LOOP = 0;
				displayInstallMenu();
			}
		}
		elsif ( lc($choice) eq "3\n" ) {
			system 'clear';
			if ( $isCrowdInstalled eq "TRUE" ) {
				print
"Crowd is already installed and therefore cannot be installed again. \nIf you believe you have received this in error, "
				  . "please edit the settings.cfg file and remove the crowd.installedVersion setting.\n\n";
				print "Please press enter to continue...";
				$input = <STDIN>;
				print "/n";
			}
			else {
				installCrowd();
				system 'clear';
				$LOOP = 0;
				displayInstallMenu();
			}
		}
		elsif ( lc($choice) eq "4\n" ) {
			system 'clear';
			if ( $isFisheyeInstalled eq "TRUE" ) {
				print
"Fisheye is already installed and therefore cannot be installed again. \nIf you believe you have received this in error, "
				  . "please edit the settings.cfg file and remove the fisheye.installedVersion setting.\n\n";
				print "Please press enter to continue...";
				$input = <STDIN>;
				print "/n";
			}
			else {
				installFisheye();
				system 'clear';
				$LOOP = 0;
				displayInstallMenu();
			}
		}
		elsif ( lc($choice) eq "5\n" ) {
			system 'clear';
			if ( $isJiraInstalled eq "TRUE" ) {
				print
"Jira is already installed and therefore cannot be installed again. \nIf you believe you have received this in error, "
				  . "please edit the settings.cfg file and remove the jira.installedVersion setting.\n\n";
				print "Please press enter to continue...";
				$input = <STDIN>;
				print "/n";
			}
			else {
				installJira();
				system 'clear';
				$LOOP = 0;
				displayInstallMenu();
			}
		}
		elsif ( lc($choice) eq "6\n" ) {
			system 'clear';
			if ( $isStashInstalled eq "TRUE" ) {
				print
"Stash is already installed and therefore cannot be installed again. \nIf you believe you have received this in error, "
				  . "please edit the settings.cfg file and remove the stash.installedVersion setting.\n\n";
				print "Please press enter to continue...";
				$input = <STDIN>;
				print "/n";
			}
			else {
				installStash();
				system 'clear';
				$LOOP = 0;
				displayInstallMenu();
			}
		}
	}
}

########################################
#Display Main Menu                     #
########################################
sub displayMainMenu {
	my $choice;
	my $main_menu;
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	my $LOOP = 1;
	while ( $LOOP == 1 ) {

		# define the main menu as a multiline string
		$main_menu = generateMenuHeader( "FULL", "ASM Main Menu", "" );

		$main_menu .= <<'END_TXT';
      Please select from the following options:

      1) Install a new application
END_TXT

		if (%appsWithUpdates) {

			#if there are values in the hash list that updates are available
			$main_menu .=
"      2) Upgrade an existing application - *** New versions available ***\n";
		}
		else {
			$main_menu .= "      2) Upgrade an existing application\n";
		}
		$main_menu .= <<'END_TXT';
      3) Uninstall an application
      4) Recover backup after failed upgrade
      5) Display advanced settings menu 
      U) Display URLs for each installed application (inc. ports)
      G) Generate Suite Config
      Q) Quit

END_TXT

		# print the main menu
		system 'clear';
		print $main_menu;

		# prompt for user's choice
		printf( "%s", "Please enter your selection: " );

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
		elsif ( lc($choice) eq "1\n" ) {
			system 'clear';
			displayInstallMenu();
		}
		elsif ( lc($choice) eq "2\n" ) {
			system 'clear';
			displayUpgradeMenu();
		}
		elsif ( lc($choice) eq "3\n" ) {
			system 'clear';
			displayUninstallMenu();
		}
		elsif ( lc($choice) eq "4\n" ) {
			system 'clear';
			displayRestoreMenu();
		}
		elsif ( lc($choice) eq "5\n" ) {
			system 'clear';
			displayAdvancedMenu();
		}
		elsif ( lc($choice) eq "u\n" ) {
			system 'clear';
			displayQuickConfig();
		}
		elsif ( lc($choice) eq "g\n" ) {
			system 'clear';
			generateSuiteConfig();
		}
		elsif ( lc($choice) eq "t\n" ) {
			system 'clear';
			my $test = <STDIN>;
		}
	}
}

########################################
#Display Restore Menu                  #
########################################
sub displayRestoreMenu {
	my $choice;
	my $menuText;
	my $isBambooBackedUp;
	my $bambooAdditionalText = "";
	my $isCrowdBackedUp;
	my $crowdAdditionalText = "";
	my $isConfluenceBackedUp;
	my $confluenceAdditionalText = "";
	my $isFisheyeBackedUp;
	my $fisheyeAdditionalText = "";
	my $isJiraBackedUp;
	my $jiraAdditionalText = "";
	my $isStashBackedUp;
	my $stashAdditionalText = "";
	my @parameterNull;
	my $input;
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	#Set up suite current install status
	@parameterNull =
	  $globalConfig->param("bamboo.latestInstallDirBackupLocation");
	if ( ( $#parameterNull == -1 )
		|| $globalConfig->param("bamboo.latestInstallDirBackupLocation") eq "" )
	{
		$isBambooBackedUp     = "FALSE";
		$bambooAdditionalText = " (Disabled - No Backup Available)";
	}
	else {
		$isBambooBackedUp = "TRUE";
	}

	@parameterNull =
	  $globalConfig->param("confluence.latestInstallDirBackupLocation");
	if ( ( $#parameterNull == -1 )
		|| $globalConfig->param("confluence.latestInstallDirBackupLocation") eq
		"" )
	{
		$isConfluenceBackedUp     = "FALSE";
		$confluenceAdditionalText = " (Disabled - No Backup Available)";
	}
	else {
		$isConfluenceBackedUp = "TRUE";
	}

	@parameterNull =
	  $globalConfig->param("crowd.latestInstallDirBackupLocation");
	if ( ( $#parameterNull == -1 )
		|| $globalConfig->param("crowd.latestInstallDirBackupLocation") eq "" )
	{
		$isCrowdBackedUp     = "FALSE";
		$crowdAdditionalText = " (Disabled - No Backup Available)";
	}
	else {
		$isCrowdBackedUp = "TRUE";
	}

	@parameterNull =
	  $globalConfig->param("fisheye.latestInstallDirBackupLocation");
	if ( ( $#parameterNull == -1 )
		|| $globalConfig->param("fisheye.latestInstallDirBackupLocation") eq
		"" )
	{
		$isFisheyeBackedUp     = "FALSE";
		$fisheyeAdditionalText = " (Disabled - No Backup Available)";
	}
	else {
		$isFisheyeBackedUp = "TRUE";
	}

	@parameterNull =
	  $globalConfig->param("jira.latestInstallDirBackupLocation");
	if ( ( $#parameterNull == -1 )
		|| $globalConfig->param("jira.latestInstallDirBackupLocation") eq "" )
	{
		$isJiraBackedUp     = "FALSE";
		$jiraAdditionalText = " (Disabled - No Backup Available)";
	}
	else {
		$isJiraBackedUp = "TRUE";
	}

	@parameterNull =
	  $globalConfig->param("stash.latestInstallDirBackupLocation");
	if ( ( $#parameterNull == -1 )
		|| $globalConfig->param("stash.latestInstallDirBackupLocation") eq "" )
	{
		$isStashBackedUp     = "FALSE";
		$stashAdditionalText = " (Disabled - No Backup Available)";
	}
	else {
		$isStashBackedUp = "TRUE";
	}

	my $LOOP = 1;
	while ( $LOOP == 1 ) {

		# define the main menu as a multiline string
		$menuText =
		  generateMenuHeader( "FULL", "ASM Restore Failed Upgrades Menu", "" );

		$menuText =
		  $menuText . "      Please select from the following options:\n\n";
		$menuText =
		  $menuText . "      1) Restore Bamboo $bambooAdditionalText\n";
		$menuText =
		  $menuText . "      2) Restore Confluence$confluenceAdditionalText\n";
		$menuText = $menuText . "      3) Restore Crowd$crowdAdditionalText\n";
		$menuText =
		  $menuText . "      4) Restore Fisheye$fisheyeAdditionalText\n";
		$menuText = $menuText . "      5) Restore JIRA$jiraAdditionalText\n";
		$menuText = $menuText . "      6) Restore Stash$stashAdditionalText\n";
		$menuText = $menuText . "      Q) Return to Main Menu\n";
		$menuText = $menuText . "\n";

		# print the main menu
		system 'clear';
		print $menuText;

		# prompt for user's choice
		printf( "%s", "Please enter you selection: " );

		# capture the choice
		$choice = <STDIN>;
		dumpSingleVarToLog( "$subname" . "_choiceEntered", $choice );

		# and finally print it
		#print "You entered: ",$choice;
		if ( $choice eq "Q\n" || $choice eq "q\n" ) {
			system 'clear';
			$LOOP = 0;
		}
		elsif ( lc($choice) eq "1\n" ) {
			system 'clear';
			if ( $isBambooBackedUp eq "FALSE" ) {
				print
"There does not appear to be any backup of Bamboo available. \nIf you believe you have received this in error, "
				  . "please contact support.\n\n";
				print "Please press enter to continue...";
				$input = <STDIN>;
				print "/n";
			}
			else {
				restoreApplicationBackup("Bamboo");
			}
		}
		elsif ( lc($choice) eq "2\n" ) {
			system 'clear';
			if ( $isConfluenceBackedUp eq "FALSE" ) {
				print
"There does not appear to be any backup of Confluence available. \nIf you believe you have received this in error, "
				  . "please contact support.\n\n";
				print "Please press enter to continue...";
				$input = <STDIN>;
				print "/n";
			}
			else {
				restoreApplicationBackup("Confluence");
			}
		}
		elsif ( lc($choice) eq "3\n" ) {
			system 'clear';
			if ( $isCrowdBackedUp eq "FALSE" ) {
				print
"There does not appear to be any backup of Crowd available. \nIf you believe you have received this in error, "
				  . "please contact support.\n\n";
				print "Please press enter to continue...";
				$input = <STDIN>;
				print "/n";
			}
			else {
				restoreApplicationBackup("Crowd");
			}
		}
		elsif ( lc($choice) eq "4\n" ) {
			system 'clear';
			if ( $isFisheyeBackedUp eq "FALSE" ) {
				print
"There does not appear to be any backup of Fisheye available. \nIf you believe you have received this in error, "
				  . "please contact support.\n\n";
				print "Please press enter to continue...";
				$input = <STDIN>;
				print "/n";
			}
			else {
				restoreApplicationBackup("Fisheye");
			}
		}
		elsif ( lc($choice) eq "5\n" ) {
			system 'clear';
			if ( $isJiraBackedUp eq "FALSE" ) {
				print
"There does not appear to be any backup of JIRA available. \nIf you believe you have received this in error, "
				  . "please contact support.\n\n";
				print "Please press enter to continue...";
				$input = <STDIN>;
				print "/n";
			}
			else {
				restoreApplicationBackup("JIRA");
			}
		}
		elsif ( lc($choice) eq "6\n" ) {
			system 'clear';
			if ( $isStashBackedUp eq "FALSE" ) {
				print
"There does not appear to be any backup of Stash available. \nIf you believe you have received this in error, "
				  . "please contact support.\n\n";
				print "Please press enter to continue...";
				$input = <STDIN>;
				print "/n";
			}
			else {
				restoreApplicationBackup("Stash");
			}
		}
	}
}

########################################
#Display Uninstall Menu                #
########################################
sub displayUninstallMenu {
	my $choice;
	my $menuText;
	my $isBambooInstalled;
	my $bambooAdditionalText = "";
	my $isCrowdInstalled;
	my $crowdAdditionalText = "";
	my $isConfluenceInstalled;
	my $confluenceAdditionalText = "";
	my $isFisheyeInstalled;
	my $fisheyeAdditionalText = "";
	my $isJiraInstalled;
	my $jiraAdditionalText = "";
	my $isStashInstalled;
	my $stashAdditionalText = "";
	my @parameterNull;
	my $input;
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	#Set up suite current install status
	@parameterNull = $globalConfig->param("bamboo.installedVersion");
	if ( ( $#parameterNull == -1 )
		|| $globalConfig->param("bamboo.installedVersion") eq "" )
	{
		$isBambooInstalled    = "FALSE";
		$bambooAdditionalText = " (Disabled - Not Currently Installed)";
	}
	else {
		$isBambooInstalled = "TRUE";
	}

	@parameterNull = $globalConfig->param("confluence.installedVersion");
	if ( ( $#parameterNull == -1 )
		|| $globalConfig->param("confluence.installedVersion") eq "" )
	{
		$isConfluenceInstalled    = "FALSE";
		$confluenceAdditionalText = " (Disabled - Not Currently Installed)";
	}
	else {
		$isConfluenceInstalled = "TRUE";
	}

	@parameterNull = $globalConfig->param("crowd.installedVersion");
	if ( ( $#parameterNull == -1 )
		|| $globalConfig->param("crowd.installedVersion") eq "" )
	{
		$isCrowdInstalled    = "FALSE";
		$crowdAdditionalText = " (Disabled - Not Currently Installed)";
	}
	else {
		$isCrowdInstalled = "TRUE";
	}

	@parameterNull = $globalConfig->param("fisheye.installedVersion");
	if ( ( $#parameterNull == -1 )
		|| $globalConfig->param("fisheye.installedVersion") eq "" )
	{
		$isFisheyeInstalled    = "FALSE";
		$fisheyeAdditionalText = " (Disabled - Not Currently Installed)";
	}
	else {
		$isFisheyeInstalled = "TRUE";
	}

	@parameterNull = $globalConfig->param("jira.installedVersion");
	if ( ( $#parameterNull == -1 )
		|| $globalConfig->param("jira.installedVersion") eq "" )
	{
		$isJiraInstalled    = "FALSE";
		$jiraAdditionalText = " (Disabled - Not Currently Installed)";
	}
	else {
		$isJiraInstalled = "TRUE";
	}

	@parameterNull = $globalConfig->param("stash.installedVersion");
	if ( ( $#parameterNull == -1 )
		|| $globalConfig->param("stash.installedVersion") eq "" )
	{
		$isStashInstalled    = "FALSE";
		$stashAdditionalText = " (Disabled - Not Currently Installed)";
	}
	else {
		$isStashInstalled = "TRUE";
	}

	my $LOOP = 1;
	while ( $LOOP == 1 ) {

		# define the main menu as a multiline string
		$menuText = generateMenuHeader( "FULL", "ASM Uninstall Menu", "" );

		$menuText =
		  $menuText . "      Please select from the following options:\n\n";
		$menuText =
		  $menuText . "      1) Uninstall Bamboo $bambooAdditionalText\n";
		$menuText = $menuText
		  . "      2) Uninstall Confluence$confluenceAdditionalText\n";
		$menuText =
		  $menuText . "      3) Uninstall Crowd$crowdAdditionalText\n";
		$menuText =
		  $menuText . "      4) Uninstall Fisheye$fisheyeAdditionalText\n";
		$menuText = $menuText . "      5) Uninstall JIRA$jiraAdditionalText\n";
		$menuText =
		  $menuText . "      6) Uninstall Stash$stashAdditionalText\n";
		$menuText = $menuText . "      Q) Return to Main Menu\n";
		$menuText = $menuText . "\n";

		# print the main menu
		system 'clear';
		print $menuText;

		# prompt for user's choice
		printf( "%s", "Please enter your selection: " );

		# capture the choice
		$choice = <STDIN>;
		dumpSingleVarToLog( "$subname" . "_choiceEntered", $choice );

		# and finally print it
		#print "You entered: ",$choice;
		if ( $choice eq "Q\n" || $choice eq "q\n" ) {
			system 'clear';
			$LOOP = 0;
		}
		elsif ( lc($choice) eq "1\n" ) {
			system 'clear';
			if ( $isBambooInstalled eq "FALSE" ) {
				print
"Bamboo is not currently installed and therefore cannot be uninstalled. \nIf you believe you have received this in error, "
				  . "please try removing the settings.cfg file and running the gather configuration utility again.\n\n";
				print "Please press enter to continue...";
				$input = <STDIN>;
				print "/n";
			}
			else {
				uninstallBamboo();
				system 'clear';
				$LOOP = 0;
				displayUninstallMenu();
			}
		}
		elsif ( lc($choice) eq "2\n" ) {
			system 'clear';
			if ( $isConfluenceInstalled eq "FALSE" ) {
				print
"Confluence is not currently installed and therefore cannot be uninstalled. \nIf you believe you have received this in error, "
				  . "please try removing the settings.cfg file and running the gather configuration utility again.\n\n";
				print "Please press enter to continue...";
				$input = <STDIN>;
				print "/n";
			}
			else {
				uninstallConfluence();
				system 'clear';
				$LOOP = 0;
				displayUninstallMenu();
			}
		}
		elsif ( lc($choice) eq "3\n" ) {
			system 'clear';
			if ( $isCrowdInstalled eq "FALSE" ) {
				print
"Crowd is not currently installed and therefore cannot be uninstalled. \nIf you believe you have received this in error, "
				  . "please try removing the settings.cfg file and running the gather configuration utility again.\n\n";
				print "Please press enter to continue...";
				$input = <STDIN>;
				print "/n";
			}
			else {
				uninstallCrowd();
				system 'clear';
				$LOOP = 0;
				displayUninstallMenu();
			}
		}
		elsif ( lc($choice) eq "4\n" ) {
			system 'clear';
			if ( $isFisheyeInstalled eq "FALSE" ) {
				print
"Fisheye is not currently installed and therefore cannot be uninstalled. \nIf you believe you have received this in error, "
				  . "please try removing the settings.cfg file and running the gather configuration utility again.\n\n";
				print "Please press enter to continue...";
				$input = <STDIN>;
				print "/n";
			}
			else {
				uninstallFisheye();
				system 'clear';
				$LOOP = 0;
				displayUninstallMenu();
			}
		}
		elsif ( lc($choice) eq "5\n" ) {
			system 'clear';
			if ( $isJiraInstalled eq "FALSE" ) {
				print
"JIRA is not currently installed and therefore cannot be uninstalled. \nIf you believe you have received this in error, "
				  . "please try removing the settings.cfg file and running the gather configuration utility again.\n\n";
				print "Please press enter to continue...";
				$input = <STDIN>;
				print "/n";
			}
			else {
				uninstallJira();
				system 'clear';
				$LOOP = 0;
				displayUninstallMenu();
			}
		}
		elsif ( lc($choice) eq "6\n" ) {
			system 'clear';
			if ( $isStashInstalled eq "FALSE" ) {
				print
"Stash is not currently installed and therefore cannot be uninstalled. \nIf you believe you have received this in error, "
				  . "please try removing the settings.cfg file and running the gather configuration utility again.\n\n";
				print "Please press enter to continue...";
				$input = <STDIN>;
				print "/n";
			}
			else {
				uninstallStash();
				system 'clear';
				$LOOP = 0;
				displayUninstallMenu();
			}
		}
	}
}

########################################
#Display Upgrade Menu                  #
########################################
sub displayUpgradeMenu {
	my $choice;
	my $menuText;
	my $isBambooInstalled;
	my $bambooAdditionalText = "";
	my $isCrowdInstalled;
	my $crowdAdditionalText = "";
	my $isConfluenceInstalled;
	my $confluenceAdditionalText = "";
	my $isFisheyeInstalled;
	my $fisheyeAdditionalText = "";
	my $isJiraInstalled;
	my $jiraAdditionalText = "";
	my $isStashInstalled;
	my $stashAdditionalText = "";
	my @parameterNull;
	my $input;
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	my $LOOP = 1;
	while ( $LOOP == 1 ) {

		checkForAvailableUpdates();

		#Set up suite current install status
		@parameterNull = $globalConfig->param("bamboo.installedVersion");
		if ( ( $#parameterNull == -1 )
			|| $globalConfig->param("bamboo.installedVersion") eq "" )
		{
			$isBambooInstalled    = "FALSE";
			$bambooAdditionalText = " (Disabled - Not Currently Installed)";
		}
		else {
			$isBambooInstalled = "TRUE";
			if ( exists $appsWithUpdates{"Bamboo"} ) {
				$bambooAdditionalText =
				    ": installed "
				  . $appsWithUpdates{"Bamboo"}->{installedVersion}
				  . " --> available "
				  . $appsWithUpdates{"Bamboo"}->{availableVersion};
			}
		}

		@parameterNull = $globalConfig->param("confluence.installedVersion");
		if ( ( $#parameterNull == -1 )
			|| $globalConfig->param("confluence.installedVersion") eq "" )
		{
			$isConfluenceInstalled    = "FALSE";
			$confluenceAdditionalText = " (Disabled - Not Currently Installed)";
		}
		else {
			$isConfluenceInstalled = "TRUE";
			if ( exists $appsWithUpdates{"Confluence"} ) {
				$confluenceAdditionalText =
				    ": installed "
				  . $appsWithUpdates{"Confluence"}->{installedVersion}
				  . " --> available "
				  . $appsWithUpdates{"Confluence"}->{availableVersion};
			}
		}

		@parameterNull = $globalConfig->param("crowd.installedVersion");
		if ( ( $#parameterNull == -1 )
			|| $globalConfig->param("crowd.installedVersion") eq "" )
		{
			$isCrowdInstalled    = "FALSE";
			$crowdAdditionalText = " (Disabled - Not Currently Installed)";
		}
		else {
			$isCrowdInstalled = "TRUE";
			if ( exists $appsWithUpdates{"Crowd"} ) {
				$crowdAdditionalText =
				    ": installed "
				  . $appsWithUpdates{"Crowd"}->{installedVersion}
				  . " --> available "
				  . $appsWithUpdates{"Crowd"}->{availableVersion};
			}
		}

		@parameterNull = $globalConfig->param("fisheye.installedVersion");
		if ( ( $#parameterNull == -1 )
			|| $globalConfig->param("fisheye.installedVersion") eq "" )
		{
			$isFisheyeInstalled    = "FALSE";
			$fisheyeAdditionalText = " (Disabled - Not Currently Installed)";
		}
		else {
			$isFisheyeInstalled = "TRUE";
			if ( exists $appsWithUpdates{"Fisheye"} ) {
				$fisheyeAdditionalText =
				    ": installed "
				  . $appsWithUpdates{"Fisheye"}->{installedVersion}
				  . " --> available "
				  . $appsWithUpdates{"Fisheye"}->{availableVersion};
			}
		}

		@parameterNull = $globalConfig->param("jira.installedVersion");
		if ( ( $#parameterNull == -1 )
			|| $globalConfig->param("jira.installedVersion") eq "" )
		{
			$isJiraInstalled    = "FALSE";
			$jiraAdditionalText = " (Disabled - Not Currently Installed)";
		}
		else {
			$isJiraInstalled = "TRUE";
			if ( exists $appsWithUpdates{"JIRA"} ) {
				$jiraAdditionalText =
				    ": installed "
				  . $appsWithUpdates{"JIRA"}->{installedVersion}
				  . " --> available "
				  . $appsWithUpdates{"JIRA"}->{availableVersion};
			}
		}

		@parameterNull = $globalConfig->param("stash.installedVersion");
		if ( ( $#parameterNull == -1 )
			|| $globalConfig->param("stash.installedVersion") eq "" )
		{
			$isStashInstalled    = "FALSE";
			$stashAdditionalText = " (Disabled - Not Currently Installed)";
		}
		else {
			$isStashInstalled = "TRUE";
			if ( exists $appsWithUpdates{"Stash"} ) {
				$stashAdditionalText =
				    ": installed "
				  . $appsWithUpdates{"Stash"}->{installedVersion}
				  . " --> available "
				  . $appsWithUpdates{"Stash"}->{availableVersion};
			}
		}

		# define the main menu as a multiline string
		$menuText = generateMenuHeader( "FULL", "ASM Upgrade Menu", "" );

		$menuText =
		  $menuText . "      1) Upgrade Bamboo $bambooAdditionalText\n";
		$menuText =
		  $menuText . "      2) Upgrade Confluence$confluenceAdditionalText\n";
		$menuText = $menuText . "      3) Upgrade Crowd$crowdAdditionalText\n";
		$menuText =
		  $menuText . "      4) Upgrade Fisheye$fisheyeAdditionalText\n";
		$menuText = $menuText . "      5) Upgrade JIRA$jiraAdditionalText\n";
		$menuText = $menuText . "      6) Upgrade Stash$stashAdditionalText\n";
		$menuText = $menuText . "      Q) Return to Main Menu\n";
		$menuText = $menuText . "\n";

		# print the main menu
		system 'clear';
		print $menuText;

		# prompt for user's choice
		printf( "%s", "Please enter you selection: " );

		# capture the choice
		$choice = <STDIN>;
		dumpSingleVarToLog( "$subname" . "_choiceEntered", $choice );

		# and finally print it
		#print "You entered: ",$choice;
		if ( $choice eq "Q\n" || $choice eq "q\n" ) {
			system 'clear';
			$LOOP = 0;
		}
		elsif ( lc($choice) eq "1\n" ) {
			system 'clear';
			if ( $isBambooInstalled eq "FALSE" ) {
				print
"Bamboo is not currently installed and therefore cannot be upgraded. \nIf you believe you have received this in error, "
				  . "please try removing the settings.cfg file and running the gather configuration utility again.\n\n";
				print "Please press enter to continue...";
				$input = <STDIN>;
				print "/n";
				system 'clear';
				$LOOP = 0;
				displayUpgradeMenu();
			}
			else {
				upgradeBamboo();
				system 'clear';
				$LOOP = 0;
				displayUpgradeMenu();
			}
		}
		elsif ( lc($choice) eq "2\n" ) {
			system 'clear';
			if ( $isConfluenceInstalled eq "FALSE" ) {
				print
"Confluence is not currently installed and therefore cannot be upgraded. \nIf you believe you have received this in error, "
				  . "please try removing the settings.cfg file and running the gather configuration utility again.\n\n";
				print "Please press enter to continue...";
				$input = <STDIN>;
				print "/n";
				system 'clear';
				$LOOP = 0;
				displayUpgradeMenu();
			}
			else {
				upgradeConfluence();
				system 'clear';
				$LOOP = 0;
				displayUpgradeMenu();
			}
		}
		elsif ( lc($choice) eq "3\n" ) {
			system 'clear';
			if ( $isCrowdInstalled eq "FALSE" ) {
				print
"Crowd is not currently installed and therefore cannot be upgraded. \nIf you believe you have received this in error, "
				  . "please try removing the settings.cfg file and running the gather configuration utility again.\n\n";
				print "Please press enter to continue...";
				$input = <STDIN>;
				print "/n";
				system 'clear';
				$LOOP = 0;
				displayUpgradeMenu();
			}
			else {
				upgradeCrowd();
				system 'clear';
				$LOOP = 0;
				displayUpgradeMenu();
			}
		}
		elsif ( lc($choice) eq "4\n" ) {
			system 'clear';
			if ( $isFisheyeInstalled eq "FALSE" ) {
				print
"Fisheye is not currently installed and therefore cannot be upgraded. \nIf you believe you have received this in error, "
				  . "please try removing the settings.cfg file and running the gather configuration utility again.\n\n";
				print "Please press enter to continue...";
				$input = <STDIN>;
				print "/n";
				system 'clear';
				$LOOP = 0;
				displayUpgradeMenu();
			}
			else {
				upgradeFisheye();
				system 'clear';
				$LOOP = 0;
				displayUpgradeMenu();
			}
		}
		elsif ( lc($choice) eq "5\n" ) {
			system 'clear';
			if ( $isJiraInstalled eq "FALSE" ) {
				print
"JIRA is not currently installed and therefore cannot be upgraded. \nIf you believe you have received this in error, "
				  . "please try removing the settings.cfg file and running the gather configuration utility again.\n\n";
				print "Please press enter to continue...";
				$input = <STDIN>;
				print "/n";
				system 'clear';
				$LOOP = 0;
				displayUpgradeMenu();
			}
			else {
				upgradeJira();
				system 'clear';
				$LOOP = 0;
				displayUpgradeMenu();
			}
		}
		elsif ( lc($choice) eq "6\n" ) {
			system 'clear';
			if ( $isStashInstalled eq "FALSE" ) {
				print
"Stash is not currently installed and therefore cannot be upgraded. \nIf you believe you have received this in error, "
				  . "please try removing the settings.cfg file and running the gather configuration utility again.\n\n";
				print "Please press enter to continue...";
				$input = <STDIN>;
				print "/n";
				system 'clear';
				$LOOP = 0;
				displayUpgradeMenu();
			}
			else {
				upgradeStash();
				system 'clear';
				$LOOP = 0;
				displayUpgradeMenu();
			}
		}
	}
}

#######################################################################
#END BOOTSTRAP AND GUI FUNCTIONS                                      #
#######################################################################

#######################################################################
#BEGIN BAMBOO MANAGER FUNCTIONS                                       #
#######################################################################

########################################
#getExistingBambooConfig               #
########################################
sub getExistingBambooConfig {
	my $cfg;
	my $defaultValue;
	my $application   = "Bamboo";
	my $mode          = "CREATE";
	my $lcApplication = lc($application);
	my $subname       = ( caller(0) )[3];
	my $serverConfigFile;
	my $serverJettyConfigFile;
	my $serverXMLFile;
	my $initPropertiesFile;
	my $javaMemParameterFile;
	my $input;
	my @parameterNull;
	my $externalCrowdInstance;
	my $LOOP = 0;
	my $returnValue;

	$log->debug("BEGIN: $subname");

	$cfg = $_[0];

	while ( $LOOP == 0 ) {

		#Ask for install dir
		genConfigItem(
			$mode,
			$cfg,
			"$lcApplication.installDir",
"Please enter the directory $application is currently installed into.",
			"",
			'(?!^.*/$)^(/.*)',
"The input you entered was not in the valid format of '/folder'. Please ensure you enter the absolute path with a "
			  . "leading '/' and NO trailing '/'.\n\n"
		);

		if ( -d escapeFilePath( $cfg->param("$lcApplication.installDir") ) ) {
			$LOOP = 1;    #break loop as directory exists
			$log->info( "$subname: Directory "
				  . escapeFilePath( $cfg->param("$lcApplication.installDir") )
				  . " exists. Proceeding..." );
			print "The directory "
			  . escapeFilePath( $cfg->param("$lcApplication.installDir") )
			  . " exists. Proceeding...\n\n";
		}
		else {
			print "The directory "
			  . escapeFilePath( $cfg->param("$lcApplication.installDir") )
			  . " does not exist. Please try again.\n\n";
			$log->info( "The directory "
				  . escapeFilePath( $cfg->param("$lcApplication.installDir") )
				  . " does not exist. Please try again." );
		}
	}

	#Ask for current installed version
	genConfigItem(
		$mode,
		$cfg,
		"$lcApplication.installedVersion",
		"Please enter the version of $application that is currently installed.",
		"",
		'^[0-9]+\.([0-9]+|[0-9]+\.[0-9]+)$',
"The input you entered was not in the valid format of 'x.x.x or x.x' (where x is a version number). Please ensure you enter the version number correctly "
		  . "\n\n"
	);

	genConfigItem(
		$mode,
		$cfg,
		"$lcApplication.javaParams",
"Enter any additional parameters currently added to the JAVA RUN_OPTS for your $application install. Just press enter if you have none.",
		"",
		"",
		""
	);

	genConfigItem(
		$mode,
		$cfg,
		"bamboo.catalinaOpts",
"Enter any additional currently added to the Java CATALINA_OPTS for your $application install. Just press enter if you have none.",
		"",
		"",
		""
	);

	if (   $cfg->param("general.apacheProxy") eq "TRUE"
		&& $cfg->param("general.apacheProxySingleDomain") eq "FALSE" )
	{
		genConfigItem(
			$mode,
			$cfg,
			"bamboo.apacheProxyHost",
"Please enter the base URL Bamboo currently runs on (i.e. the proxyName such as yourdomain.com).",
			"",
			$hostnameRegex,
"The input you entered was not in the valid format of 'yourdomain.com' or 'subdomain.yourdomain.com'. Please try again.\n\n"
		);

		genBooleanConfigItem( $mode, $cfg, "bamboo.apacheProxySSL",
			"Do you currently run Bamboo over SSL.", "no" );

		genConfigItem(
			$mode,
			$cfg,
			"bamboo.apacheProxyPort",
"Please enter the port number that Apache currently serves Bamboo on (80 for HTTP, 443 for HTTPS in standard situations).",
			"80",
			'^([0-9]*)$',
"The input you entered was not a valid port number, please try again.\n\n"
		);
	}

	genConfigItem(
		$mode,
		$cfg,
		"bamboo.serverPort",
"Please enter the SERVER port Bamboo will run on (note this is the control port not the port you access in a browser).",
		"8007",
		'^([0-9]*)$',
"The port number you entered contained invalid characters. Please ensure you enter only digits.\n\n"
	);

	checkConfiguredPort( $application, "bamboo.serverPort", $cfg );

	#Set up some defaults for Bamboo
	$cfg->param( "bamboo.tomcatDir", "" )
	  ;    #we leave these blank deliberately due to the way Bamboo works
	$cfg->param( "bamboo.webappDir", "" )
	  ;    #we leave these blank deliberately due to the way Bamboo works
	$cfg->param( "bamboo.processSearchParameter1", "java" );
	$cfg->param( "bamboo.processSearchParameter2",
		$cfg->param("bamboo.installDir") );

	genBooleanConfigItem(
		$mode,
		$cfg,
		"$lcApplication.runAsService",
"Does your $application instance run as a service (i.e. runs on boot)? yes/no.",
		"yes"
	);

	@parameterNull = $cfg->param("general.externalCrowdInstance");

	if ( $#parameterNull == -1 ) {
		$externalCrowdInstance = "FALSE";
	}
	else {
		$externalCrowdInstance = $cfg->param("general.externalCrowdInstance");
	}

	if (   $externalCrowdInstance eq "TRUE"
		|| $cfg->param("crowd.enable") eq "TRUE" )
	{
		genBooleanConfigItem(
			$mode,
			$cfg,
			"bamboo.crowdIntegration",
"Will you be using Crowd as the authentication backend for Bamboo? yes/no.",
			"yes"
		);

		if ( $cfg->param("bamboo.crowdIntegration") eq "TRUE" ) {
			genBooleanConfigItem( $mode, $cfg, "bamboo.crowdSSO",
				"Will you be using Crowd for Single Sign On (SSO)? yes/no.",
				"yes" );
		}
	}
	else {
		$cfg->param( "bamboo.crowdIntegration", "FALSE" );
		$cfg->param( "bamboo.crowdSSO",         "FALSE" );
	}

	if (
		compareTwoVersions( $cfg->param("$lcApplication.installedVersion"),
			"5.1.0" ) ne "GREATER"
	  )
	{
		$serverConfigFile =
		  escapeFilePath( $cfg->param("$lcApplication.installDir") )
		  . "/conf/wrapper.conf";

		$serverJettyConfigFile =
		  escapeFilePath( $cfg->param("$lcApplication.installDir") )
		  . "/webapp/WEB-INF/classes/jetty.xml";

		print
"Please wait, attempting to get the $application data/home directory from it's config files...\n\n";
		$log->info(
"$subname: Attempting to get $application data directory from config file $serverConfigFile."
		);

		#get data/home directory
		$returnValue = getLineFromFile(
			escapeFilePath( $cfg->param("$lcApplication.installDir") )
			  . "/webapp/WEB-INF/classes/bamboo-init.properties",
			"bamboo.home=", ".*=(.*)"
		);

		if ( $returnValue eq "NOTFOUND" ) {
			$log->info(
"$subname: Unable to locate $application data directory. Asking user for input."
			);
			genConfigItem(
				$mode,
				$cfg,
				"$lcApplication.dataDir",
"Unable to find the data directory in the expected location in the $application config. Please enter the directory $application"
				  . "'s data is *currently* stored in.",
				"",
				'(?!^.*/$)^(/.*)',
"The input you entered was not in the valid format of '/folder'. Please ensure you enter the absolute path with a "
				  . "leading '/' and NO trailing '/'.\n\n"
			);
		}
		else {
			$cfg->param( "$lcApplication.dataDir", $returnValue );
			print
"$application data directory has been found successfully and added to the config file...\n\n";
			$log->info(
"$subname: $application data directory found and added to config."
			);
		}

		#getContextFromFile
		$returnValue = "";

		print
"Please wait, attempting to get the $application context from it's config files...\n\n";
		$log->info(
"$subname: Attempting to get $application context from config file $serverConfigFile."
		);
		$returnValue =
		  getLineFromFile( $serverConfigFile, "wrapper.app.parameter.4=",
			".*=(.*)" );

		if ( $returnValue eq "NOTFOUND" ) {
			$log->info(
"$subname: Unable to locate $application context. Asking user for input."
			);
			genConfigItem(
				$mode,
				$cfg,
				"$lcApplication.appContext",
"Unable to find the context in the expected location in the $application config. Please enter the context that $application *currently* runs under (i.e. /bamboo). Write NULL to blank out the context.",
				"/bamboo",
				'(?!^.*/$)^(/.*)',
"The input you entered was not in the valid format of '/folder'. Please ensure you enter the path with a "
				  . "leading '/' and NO trailing '/'.\n\n"
			);
		}
		else {
			if ( $returnValue eq "" ) {
				$returnValue = "NULL";
			}
			$cfg->param( "$lcApplication.appContext", $returnValue );
			print
"$application context has been found successfully and added to the config file...\n\n";
			$log->info(
				"$subname: $application context found and added to config.");
		}

		$returnValue = "";

		print
"Please wait, attempting to get the $application connectorPort from it's config files...\n\n";
		$log->info(
"$subname: Attempting to get $application connectorPort from config file $serverConfigFile."
		);

		#Get connector port from file
		$returnValue =
		  getLineFromFile( $serverConfigFile, "wrapper.app.parameter.2",
			".*=(.*)" );

		if ( $returnValue eq "NOTFOUND" ) {
			$log->info(
"$subname: Unable to locate $application connectorPort. Asking user for input."
			);
			genConfigItem(
				$mode,
				$cfg,
				"$lcApplication.connectorPort",
"Unable to find the connector port in the expected location in the $application config. Please enter the Connector port $application *currently* runs on (note this is the port you access in the browser OR proxy to with another web server).",
				"8085",
				'^([0-9]*)$',
"The port number you entered contained invalid characters. Please ensure you enter only digits.\n\n"
			);

			$returnValue = "";

			print
"Please wait, attempting to get the $application Xms java memory parameter from it's config files...\n\n";
			$log->info(
"$subname: Attempting to get $application Xms java memory parameter from config file $serverConfigFile."
			);
			$returnValue = getLineFromBambooWrapperConf( $serverConfigFile,
				"wrapper.java.additional.", "-Xms" );
			if ( $returnValue eq "NOTFOUND" ) {
				$log->info(
"$subname: Unable to locate $application Xms memory parameter. Asking user for input."
				);
				genConfigItem(
					$mode,
					$cfg,
					"$lcApplication.javaMinMemory",
"Unable to find the java Xms memory parameter in the expected location in the $application config. Please enter the minimum amount of memory *currently* assigned to $application.",
					"256m",
					'^([0-9]*m)$',
"The memory value you entered is in an invalid format. Please ensure you use the format '1234m'. (i.e. '256m')"
				);
			}
			else {
				$cfg->param( "$lcApplication.javaMinMemory", $returnValue );
				print
"$application Xms java memory parameter has been found successfully and added to the config file...\n\n";
				$log->info(
"$subname: $application Xms java memory parameter found and added to config."
				);
			}
		}
		else {
			$cfg->param( "$lcApplication.connectorPort", $returnValue );
			print
"$application connectorPort has been found successfully and added to the config file...\n\n";
			$log->info(
"$subname: $application connectorPort found and added to config."
			);
		}

		$returnValue = "";

		print
"Please wait, attempting to get the $application Xmx java memory parameter from it's config files...\n\n";
		$log->info(
"$subname: Attempting to get $application Xmx java memory parameter from config file $serverConfigFile."
		);
		$returnValue = getLineFromBambooWrapperConf( $serverConfigFile,
			"wrapper.java.additional.", "-Xmx" );
		if ( $returnValue eq "NOTFOUND" ) {
			$log->info(
"$subname: Unable to locate $application Xmx memory parameter. Asking user for input."
			);
			genConfigItem(
				$mode,
				$cfg,
				"$lcApplication.javaMaxMemory",
"Unable to find the java Xmx memory parameter in the expected location in the $application config. Please enter the maximum amount of memory *currently* assigned to $application.",
				"512m",
				'^([0-9]*m)$',
"The memory value you entered is in an invalid format. Please ensure you use the format '1234m'. (i.e. '256m')"
			);
		}
		else {
			$cfg->param( "$lcApplication.javaMaxMemory", $returnValue );
			print
"$application Xmx java memory parameter has been found successfully and added to the config file...\n\n";
			$log->info(
"$subname: $application Xmx java memory parameter found and added to config."
			);
		}

		$returnValue = "";

		print
"Please wait, attempting to get the $application XX:MaxPermSize java memory parameter from it's config files...\n\n";
		$log->info(
"$subname: Attempting to get $application XX:MaxPermSize java memory parameter from config file $serverConfigFile."
		);
		$returnValue = getLineFromBambooWrapperConf( $serverConfigFile,
			"wrapper.java.additional.", "-XX:MaxPermSize=" );
		if ( $returnValue eq "NOTFOUND" ) {
			$log->info(
"$subname: Unable to locate $application XX:MaxPermSize memory parameter. Asking user for input."
			);
			genConfigItem(
				$mode,
				$cfg,
				"$lcApplication.javaMaxPermSize",
"Unable to find the java XX:MaxPermSize memory parameter in the expected location in the $application config. Please enter the maximum amount of permGen memory *currently* assigned to $application.",
				"256m",
				'^([0-9]*m)$',
"The memory value you entered is in an invalid format. Please ensure you use the format '1234m'. (i.e. '256m')"
			);
		}
		else {
			$cfg->param( "$lcApplication.javaMaxPermSize", $returnValue );
			print
"$application XX:MaxPermSize java memory parameter has been found successfully and added to the config file...\n\n";
			$log->info(
"$subname: $application XX:MaxPermSize java memory parameter found and added to config."
			);
		}

	}
	else {

		#Do Install for Bamboo Version 5.1.0 or newer
		$serverXMLFile =
		  escapeFilePath( $cfg->param("$lcApplication.installDir") )
		  . "/conf/server.xml";
		$initPropertiesFile =
		    escapeFilePath( $cfg->param("$lcApplication.installDir") )
		  . $cfg->param("$lcApplication.webappDir")
		  . "/WEB-INF/classes/$lcApplication-init.properties";
		$javaMemParameterFile =
		  escapeFilePath( $cfg->param("$lcApplication.installDir") )
		  . "/bin/setenv.sh";

		print
"Please wait, attempting to get the $application data/home directory from it's config files...\n\n";
		$log->info(
"$subname: Attempting to get $application data directory from config file."
		);

		#get data/home directory
		$returnValue = getLineFromFile(
			escapeFilePath( $cfg->param("$lcApplication.installDir") )
			  . "/atlassian-bamboo/WEB-INF/classes/bamboo-init.properties",
			"bamboo.home=", ".*=(.*)"
		);

		if ( $returnValue eq "NOTFOUND" ) {
			$log->info(
"$subname: Unable to locate $application data directory. Asking user for input."
			);
			genConfigItem(
				$mode,
				$cfg,
				"$lcApplication.dataDir",
"Unable to find the data directory in the expected location in the $application config. Please enter the directory $application"
				  . "'s data is *currently* stored in.",
				"",
				'(?!^.*/$)^(/.*)',
"The input you entered was not in the valid format of '/folder'. Please ensure you enter the absolute path with a "
				  . "leading '/' and NO trailing '/'.\n\n"
			);
		}
		else {
			$cfg->param( "$lcApplication.dataDir", $returnValue );
			print
"$application data directory has been found successfully and added to the config file...\n\n";
			$log->info(
"$subname: $application data directory found and added to config."
			);
		}

		#getContextFromFile
		$returnValue = "";

		print
"Please wait, attempting to get the $application context from it's config files...\n\n";
		$log->info(
			"$subname: Attempting to get $application context from config file."
		);
		$returnValue =
		  getXMLAttribute( $serverXMLFile, "//////Context", "path" );

		if ( $returnValue eq "NOTFOUND" ) {
			$log->info(
"$subname: Unable to locate $application context. Asking user for input."
			);
			genConfigItem(
				$mode,
				$cfg,
				"$lcApplication.appContext",
"Unable to find the context in the expected location in the $application config. Please enter the context that $application *currently* runs under (i.e. /bamboo). Write NULL to blank out the context.",
				"/bamboo",
				'(?!^.*/$)^(/.*)',
"The input you entered was not in the valid format of '/folder'. Please ensure you enter the path with a "
				  . "leading '/' and NO trailing '/'.\n\n"
			);
		}
		else {
			if ( $returnValue eq "" ) {
				$returnValue = "NULL";
			}
			$cfg->param( "$lcApplication.appContext", $returnValue );
			print
"$application context has been found successfully and added to the config file...\n\n";
			$log->info(
				"$subname: $application context found and added to config.");
		}

		$returnValue = "";

		print
"Please wait, attempting to get the $application connectorPort from it's config files...\n\n";
		$log->info(
"$subname: Attempting to get $application connectorPort from config file $serverXMLFile."
		);

		#Get connector port from file
		$returnValue =
		  getXMLAttribute( $serverXMLFile, "///Connector", "port" );

		if ( $returnValue eq "NOTFOUND" ) {
			$log->info(
"$subname: Unable to locate $application connectorPort. Asking user for input."
			);
			genConfigItem(
				$mode,
				$cfg,
				"$lcApplication.connectorPort",
"Unable to find the connector port in the expected location in the $application config. Please enter the Connector port $application *currently* runs on (note this is the port you access in the browser OR proxy to with another web server).",
				"8085",
				'^([0-9]*)$',
"The port number you entered contained invalid characters. Please ensure you enter only digits.\n\n"
			);
		}
		else {
			$cfg->param( "$lcApplication.connectorPort", $returnValue );
			print
"$application connectorPort has been found successfully and added to the config file...\n\n";
			$log->info(
"$subname: $application connectorPort found and added to config."
			);
		}

		$returnValue = "";

		print
"Please wait, attempting to get the $application Xms java memory parameter from it's config files...\n\n";
		$log->info(
"$subname: Attempting to get $application Xms java memory parameter from config file $javaMemParameterFile."
		);
		$returnValue =
		  getLineFromFile( $javaMemParameterFile, "JVM_MINIMUM_MEMORY",
			".*\\s?=\\s?(.*)" );
		if ( $returnValue eq "NOTFOUND" ) {
			$log->info(
"$subname: Unable to locate $application Xms memory parameter. Asking user for input."
			);
			genConfigItem(
				$mode,
				$cfg,
				"$lcApplication.javaMinMemory",
"Unable to find the java Xms memory parameter in the expected location in the $application config. Please enter the minimum amount of memory *currently* assigned to $application.",
				"256m",
				'^([0-9]*m)$',
"The memory value you entered is in an invalid format. Please ensure you use the format '1234m'. (i.e. '256m')"
			);
		}
		else {
			$cfg->param( "$lcApplication.javaMinMemory", $returnValue );
			print
"$application Xms java memory parameter has been found successfully and added to the config file...\n\n";
			$log->info(
"$subname: $application Xms java memory parameter found and added to config."
			);
		}

		$returnValue = "";

		print
"Please wait, attempting to get the $application Xmx java memory parameter from it's config files...\n\n";
		$log->info(
"$subname: Attempting to get $application Xmx java memory parameter from config file $javaMemParameterFile."
		);
		$returnValue =
		  getLineFromFile( $javaMemParameterFile, "JVM_MAXIMUM_MEMORY",
			".*\\s?=\\s?(.*)" );
		if ( $returnValue eq "NOTFOUND" ) {
			$log->info(
"$subname: Unable to locate $application Xmx memory parameter. Asking user for input."
			);
			genConfigItem(
				$mode,
				$cfg,
				"$lcApplication.javaMaxMemory",
"Unable to find the java Xmx memory parameter in the expected location in the $application config. Please enter the maximum amount of memory *currently* assigned to $application.",
				"512m",
				'^([0-9]*m)$',
"The memory value you entered is in an invalid format. Please ensure you use the format '1234m'. (i.e. '256m')"
			);
		}
		else {
			$cfg->param( "$lcApplication.javaMaxMemory", $returnValue );
			print
"$application Xmx java memory parameter has been found successfully and added to the config file...\n\n";
			$log->info(
"$subname: $application Xmx java memory parameter found and added to config."
			);
		}

		$returnValue = "";

		print
"Please wait, attempting to get the $application XX:MaxPermSize java memory parameter from it's config files...\n\n";
		$log->info(
"$subname: Attempting to get $application XX:MaxPermSize java memory parameter from config file $javaMemParameterFile."
		);
		$returnValue =
		  getLineFromFile( $javaMemParameterFile, "BAMBOO_MAX_PERM_SIZE",
			".*\\s?=\\s?(.*)" );
		if ( $returnValue eq "NOTFOUND" ) {
			$log->info(
"$subname: Unable to locate $application XX:MaxPermSize memory parameter. Asking user for input."
			);
			genConfigItem(
				$mode,
				$cfg,
				"$lcApplication.javaMaxPermSize",
"Unable to find the java XX:MaxPermSize memory parameter in the expected location in the $application config. Please enter the maximum amount of permGen memory *currently* assigned to $application.",
				"256m",
				'^([0-9]*m)$',
"The memory value you entered is in an invalid format. Please ensure you use the format '1234m'. (i.e. '256m')"
			);
		}
		else {
			$cfg->param( "$lcApplication.javaMaxPermSize", $returnValue );
			print
"$application XX:MaxPermSize java memory parameter has been found successfully and added to the config file...\n\n";
			$log->info(
"$subname: $application XX:MaxPermSize java memory parameter found and added to config."
			);
		}

		if (   $cfg->param("general.apacheProxy") eq "TRUE"
			&& $cfg->param("general.apacheProxySingleDomain") eq "FALSE" )
		{
			$returnValue = "";

			print
"Please wait, attempting to get the Apache proxy base hostname configuration for $application from the configuration files...\n\n";
			$log->info(
"$subname: Attempting to get $application proxyName from config file $serverXMLFile."
			);
			$returnValue =
			  getXMLAttribute( $serverXMLFile, "///Connector", "proxyName" );

			if ( $returnValue eq "NOTFOUND" ) {
				$log->info(
"$subname: Unable to locate $application proxyName. Asking user for input."
				);
				genConfigItem(
					$mode,
					$cfg,
					"$lcApplication.apacheProxyHost",
"Unable to find the base hostname attribute in the expected location in the $application config. Please enter the base URL that will be serving the site (i.e. the proxyName such as yourdomain.com).",
					"",
					$hostnameRegex,
"The input you entered was not in the valid format of 'yourdomain.com' or 'subdomain.yourdomain.com'. Please try again.\n\n"
				);
			}
			else {
				$cfg->param( "$lcApplication.apacheProxyHost", $returnValue );
				print
"$application base hostname has been found successfully and added to the config file...\n\n";
				$log->info(
"$subname: $application base hostname found and added to config."
				);
			}

			$returnValue = "";

			print
"Please wait, attempting to get the Apache proxy scheme configuration for $application from the configuration files...\n\n";
			$log->info(
"$subname: Attempting to get $application proxy scheme from config file $serverXMLFile."
			);
			$returnValue =
			  getXMLAttribute( $serverXMLFile, "///Connector", "scheme" );

			if ( $returnValue eq "NOTFOUND" ) {
				$log->info(
"$subname: Unable to locate $application proxy scheme. Asking user for input."
				);
				genBooleanConfigItem(
					$mode,
					$cfg,
					"$lcApplication.apacheProxySSL",
"Unable to locate the Apache proxy scheme configuration in $application config. Will you be running $application over SSL.",
					"no"
				);
			}
			else {
				if ( $returnValue eq "http" ) {
					$log->info(
"$subname: return value for Apache Proxy Scheme config is 'http'."
					);
					$cfg->param( "$lcApplication.apacheProxySSL", "FALSE" );
				}
				elsif ( $returnValue eq "https" ) {
					$log->info(
"$subname: return value for Apache Proxy Scheme config is 'http'."
					);
					$cfg->param( "$lcApplication.apacheProxySSL", "TRUE" );
				}
				else {
					$log->info(
"$subname: return value for Apache Proxy Scheme config is 'UNKNOWN' This is not good."
					);
					$cfg->param( "$lcApplication.apacheProxySSL", "UNKNOWN" );
				}

				print
"$application Apache Proxy scheme has been found successfully and added to the config file...\n\n";
				$log->info(
"$subname: $application proxy scheme found and added to config."
				);
			}

			$returnValue = "";

			print
"Please wait, attempting to get the Apache proxy port configuration for $application from the configuration files...\n\n";
			$log->info(
"$subname: Attempting to get $application proxyPort from config file $serverXMLFile."
			);
			$returnValue =
			  getXMLAttribute( $serverXMLFile, "///Connector", "proxyPort" );

			if ( $returnValue eq "NOTFOUND" ) {
				$log->info(
"$subname: Unable to locate $application proxyPort. Asking user for input."
				);
				genConfigItem(
					$mode,
					$cfg,
					"$lcApplication.apacheProxyPort",
"Unable to find the Apache proxy port attribute in the expected location in the $application config. Please enter the port number that Apache currently serves on (80 for HTTP, 443 for HTTPS in standard situations).",
					"80/443",
					'^([0-9]*)$',
"The input you entered was not a valid port number, please try again.\n\n"
				);
			}
			else {
				$cfg->param( "$lcApplication.apacheProxyPort", $returnValue );
				print
"$application base hostname has been found successfully and added to the config file...\n\n";
				$log->info(
"$subname: $application base hostname found and added to config."
				);
			}
		}

	}

	$returnValue = "";

	#getOSuser
	open( my $inputFileHandle,
		'<', escapeFilePath( $cfg->param("$lcApplication.installDir") ) )
	  or $log->logdie(
"Unable to open install dir for $application to test who owns it. Really this should never happen as we have already tested that the directory exists."
	  );
	my (
		$dev,   $ino,     $fileMode, $nlink, $uid,
		$gid,   $rdev,    $size,     $atime, $mtime,
		$ctime, $blksize, $blocks
	) = stat($inputFileHandle);
	$returnValue = getpwuid($uid);
	close $inputFileHandle;

	#confirmWithUserThatIsTheCorrectOSUser
	$input = getBooleanInput(
"We have detected that the user $application runs under is '$returnValue'. Is this correct? yes/no [yes]: "
	);
	print "\n";
	if ( $input eq "default" || $input eq "yes" ) {
		$cfg->param( "$lcApplication.osUser", $returnValue );
		print
		  "The osUser $returnValue has been added to the config file...\n\n";
		$log->info(
"$subname: User confirmed that the user $application runs under is $returnValue. This has been added to the config."
		);
	}
	else {
		genConfigItem(
			$mode,
			$cfg,
			"$lcApplication.osUser",
"In that case please enter the user that $application *currently* runs under.",
			"",
			'^([a-zA-Z0-9]*)$',
"The user you entered was in an invalid format. Please ensure you enter only letters and numbers without any spaces or other characters.\n\n"
		);

	}

	$cfg->param( "$lcApplication.enable", "TRUE" );

	$cfg->write($configFile);
	loadSuiteConfig();

	print
"We now have the $application config and it has been written to the config file. Please press enter to continue.\n";
	$input = <STDIN>;

}

########################################
#GenerateBambooConfig                  #
########################################
sub generateBambooConfig {
	my $cfg;
	my $mode;
	my $defaultValue;
	my @parameterNull;
	my $externalCrowdInstance;
	my $application = "Bamboo";
	my $subname     = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	$mode = $_[0];
	$cfg  = $_[1];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_mode", $mode );

	genConfigItem(
		$mode,
		$cfg,
		"bamboo.installDir",
		"Please enter the directory Bamboo will be installed into.",
		$cfg->param("general.rootInstallDir") . "/bamboo",
		'(?!^.*/$)^(/.*)',
"The input you entered was not in the valid format of '/folder'. Please ensure you enter the absolute path with a "
		  . "leading '/' and NO trailing '/'.\n\n"
	);

	genConfigItem(
		$mode,
		$cfg,
		"bamboo.dataDir",
		"Please enter the directory Bamboo's data will be stored in.",
		$cfg->param("general.rootDataDir") . "/bamboo",
		'(?!^.*/$)^(/.*)',
"The input you entered was not in the valid format of '/folder'. Please ensure you enter the absolute path with a "
		  . "leading '/' and NO trailing '/'.\n\n"
	);
	genConfigItem(
		$mode,
		$cfg,
		"bamboo.osUser",
		"Enter the user that Bamboo will run under.",
		"bamboo",
		'^([a-zA-Z0-9]*)$',
"The user you entered was in an invalid format. Please ensure you enter only letters and numbers without any spaces or other characters.\n\n"
	);

	genConfigItem(
		$mode,
		$cfg,
		"bamboo.appContext",
"Enter the context that Bamboo should run under (i.e. /bamboo). Write NULL to blank out the context.",
		"/bamboo",
		'(?!^.*/$)^(/.*)',
"The input you entered was not in the valid format of '/folder'. Please ensure you enter the path with a "
		  . "leading '/' and NO trailing '/'.\n\n"
	);
	genConfigItem(
		$mode,
		$cfg,
		"bamboo.connectorPort",
"Please enter the Connector port Bamboo will run on (note this is the port you will access in the browser).",
		"8085",
		'^([0-9]*)$',
"The port number you entered contained invalid characters. Please ensure you enter only digits.\n\n"
	);
	checkConfiguredPort( $application, "bamboo.connectorPort", $cfg );

	genConfigItem(
		$mode,
		$cfg,
		"bamboo.serverPort",
"Please enter the SERVER port Bamboo will run on (note this is the control port not the port you access in a browser).",
		"8007",
		'^([0-9]*)$',
"The port number you entered contained invalid characters. Please ensure you enter only digits.\n\n"
	);

	checkConfiguredPort( $application, "bamboo.serverPort", $cfg );

	genConfigItem(
		$mode,
		$cfg,
		"bamboo.javaParams",
"Enter any additional parameters you would like to add to the Java RUN_OPTS.",
		"",
		"",
		""
	);

	genConfigItem(
		$mode,
		$cfg,
		"bamboo.catalinaOpts",
"Enter any additional parameters you would like to add to the Java CATALINA_OPTS.",
		"",
		"",
		""
	);

	genConfigItem(
		$mode,
		$cfg,
		"bamboo.javaMinMemory",
"Enter the minimum amount of memory you would like to assign to Bamboo.",
		"256m",
		'^([0-9]*m)$',
"The memory value you entered is in an invalid format. Please ensure you use the format '1234m'. (i.e. '256m')"
	);

	genConfigItem(
		$mode,
		$cfg,
		"bamboo.javaMaxMemory",
"Enter the maximum amount of memory you would like to assign to Bamboo.",
		"512m",
		'^([0-9]*m)$',
"The memory value you entered is in an invalid format. Please ensure you use the format '1234m'. (i.e. '256m')"
	);

	genConfigItem(
		$mode,
		$cfg,
		"bamboo.javaMaxPermSize",
"Enter the amount of memory for the MAX_PERM_SIZE parameter that you would like to assign to Bamboo.",
		"256m",
		'^([0-9]*m)$',
"The memory value you entered is in an invalid format. Please ensure you use the format '1234m'. (i.e. '256m')"
	);

	if (   $cfg->param("general.apacheProxy") eq "TRUE"
		&& $cfg->param("general.apacheProxySingleDomain") eq "FALSE" )
	{
		genConfigItem(
			$mode,
			$cfg,
			"bamboo.apacheProxyHost",
"Please enter the base URL that will be serving the site (i.e. the proxyName such as yourdomain.com).",
			"",
			$hostnameRegex,
"The input you entered was not in the valid format of 'yourdomain.com' or 'subdomain.yourdomain.com'. Please try again.\n\n"
		);

		genBooleanConfigItem( $mode, $cfg, "bamboo.apacheProxySSL",
			"Will you be running Bamboo over SSL.", "no" );

		genConfigItem(
			$mode,
			$cfg,
			"bamboo.apacheProxyPort",
"Please enter the port number that Apache will serve on (80 for HTTP, 443 for HTTPS in standard situations).",
			"80",
			'^([0-9]*)$',
"The input you entered was not a valid port number, please try again.\n\n"
		);
	}

	genBooleanConfigItem( $mode, $cfg, "bamboo.runAsService",
		"Would you like to run Bamboo as a service? yes/no.", "yes" );

	@parameterNull = $cfg->param("general.externalCrowdInstance");

	if ( $#parameterNull == -1 ) {
		$externalCrowdInstance = "FALSE";
	}
	else {
		$externalCrowdInstance = $cfg->param("general.externalCrowdInstance");
	}

	if (   $externalCrowdInstance eq "TRUE"
		|| $cfg->param("crowd.enable") eq "TRUE" )
	{
		genBooleanConfigItem(
			$mode,
			$cfg,
			"bamboo.crowdIntegration",
"Will you be using Crowd as the authentication backend for Bamboo? yes/no.",
			"yes"
		);

		if ( $cfg->param("bamboo.crowdIntegration") eq "TRUE" ) {
			genBooleanConfigItem( $mode, $cfg, "bamboo.crowdSSO",
				"Will you be using Crowd for Single Sign On (SSO)? yes/no.",
				"yes" );
		}
	}
	else {
		$cfg->param( "bamboo.crowdIntegration", "FALSE" );
		$cfg->param( "bamboo.crowdSSO",         "FALSE" );
	}

	#Set up some defaults for Bamboo
	$cfg->param( "bamboo.tomcatDir", "" )
	  ;    #we leave these blank deliberately due to the way Bamboo works
	$cfg->param( "bamboo.webappDir", "/atlassian-bamboo" )
	  ;    #we leave these blank deliberately due to the way Bamboo works
	$cfg->param( "bamboo.processSearchParameter1", "java" );
	$cfg->param( "bamboo.processSearchParameter2",
		$cfg->param("bamboo.installDir") );

	$cfg->param( "bamboo.enable", "TRUE" );
}

########################################
#Install Bamboo                        #
########################################
sub installBamboo {
	my $input;
	my $application = "Bamboo";
	my $osUser;
	my $serverConfigFile;
	my $serverJettyConfigFile;
	my $javaMemParameterFile;
	my $lcApplication;
	my $downloadArchivesUrl =
	  "http://www.atlassian.com/software/bamboo/download-archives";
	my $configFile;
	my @requiredConfigItems;
	my @requiredCrowdConfigItems;
	my @parameterNull;
	my $javaOptsValue;
	my $catalinaOptsValue;
	my $tomcatDir;
	my $WrapperDownloadFile;
	my $WrapperDownloadUrlFor64Bit =
"https://confluence.atlassian.com/download/attachments/289276785/Bamboo_64_Bit_Wrapper.zip?version=1&modificationDate=1346435557878&api=v2";
	my $subname = ( caller(0) )[3];

	#New variables for installs above Bamboo version 5.1.0
	my $serverXMLFile;
	my $initPropertiesFile;
	my $serverXLMLFile;

	#End new variables

	$log->debug("BEGIN: $subname");

	#Set up list of config items that are requred for this install to run
	$lcApplication       = lc($application);
	@requiredConfigItems = (
		"bamboo.appContext",              "bamboo.enable",
		"bamboo.dataDir",                 "bamboo.installDir",
		"bamboo.runAsService",            "bamboo.osUser",
		"bamboo.connectorPort",           "bamboo.javaMinMemory",
		"bamboo.javaMaxMemory",           "bamboo.javaMaxPermSize",
		"bamboo.processSearchParameter1", "bamboo.processSearchParameter2",
		"bamboo.crowdIntegration",        "bamboo.webappDir",
		"bamboo.serverPort"
	);

	if ( $globalConfig->param("general.apacheProxy") eq "TRUE" ) {
		if (
			$globalConfig->param("general.apacheProxySingleDomain") eq "FALSE" )
		{
			push( @requiredConfigItems, "bamboo.apacheProxyPort" );
			push( @requiredConfigItems, "bamboo.apacheProxySSL" );
			push( @requiredConfigItems, "bamboo.apacheProxyHost" );
		}
	}

	#Force config regeneration if bamboo process search parameter is out of date
	if ( $globalConfig->param("bamboo.processSearchParameter2") ne
		$globalConfig->param("bamboo.installDir") )
	{

#Below we push a completely invalid required config item, it will never exist therefore it will force config generation
		push( @requiredConfigItems,
			"bamboo.thisConfigWillNeverExistThereforeForceConfigGeneration" );
	}

	#Run generic installer steps
	installGeneric( $application, $downloadArchivesUrl, \@requiredConfigItems );
	$osUser = $globalConfig->param("$lcApplication.osUser")
	  ; #we get this after install in CASE the installer changes the configured user in future

	#Force update config items for search parameters
	$globalConfig->param( "$lcApplication.processSearchParameter1", "java" );
	$globalConfig->param(
		"$lcApplication.processSearchParameter2",
		$globalConfig->param("$lcApplication.installDir")
	);
	$globalConfig->write($configFile);
	loadSuiteConfig();

	#Perform application specific configuration
	print "Applying configuration settings to the install, please wait...\n\n";

#Check if we are installing version below 5.1.0 to maintain backwards compatibility
	if (
		compareTwoVersions(
			$globalConfig->param("$lcApplication.installedVersion"), "5.1.0" )
		ne "GREATER"
	  )
	{
		$serverConfigFile =
		  escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
		  . "/conf/wrapper.conf";

		$serverJettyConfigFile =
		  escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
		  . "/webapp/WEB-INF/classes/jetty.xml";

		print "Creating backup of config files...\n\n";
		$log->info("$subname: Backing up config files.");

		backupFile( $serverConfigFile, $osUser );
		backupFile(
			escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
			  . "/webapp/WEB-INF/classes/bamboo-init.properties",
			$osUser
		);
		$javaMemParameterFile =
		  escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
		  . "/conf/wrapper.conf";
		backupFile( $javaMemParameterFile, $osUser );

		print "Applying port numbers to server config...\n\n";

		updateLineInFile(
			$serverConfigFile,
			"wrapper.app.parameter.2",
			"wrapper.app.parameter.2="
			  . $globalConfig->param("$lcApplication.connectorPort"),
			""
		);

		my $bambooContext;
		if ( $globalConfig->param("$lcApplication.appContext") eq "NULL" ) {
			$bambooContext = "/";
		}
		else {
			$bambooContext = $globalConfig->param("$lcApplication.appContext");
		}

		#Apply application context
		updateLineInFile( $serverConfigFile, "wrapper.app.parameter.4",
			"wrapper.app.parameter.4=" . $bambooContext, "" );

		#Edit Bamboo config file to reference homedir
		$log->info(
			"$subname: Applying homedir in "
			  . escapeFilePath(
				$globalConfig->param("$lcApplication.installDir")
			  )
			  . "/webapp/WEB-INF/classes/bamboo-init.properties"
		);
		print "Applying home directory to config...\n\n";
		updateLineInFile(
			escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
			  . "/webapp/WEB-INF/classes/bamboo-init.properties",
			"bamboo.home",
			"$lcApplication.home="
			  . escapeFilePath(
				$globalConfig->param("$lcApplication.dataDir") ),
			"#bamboo.home=C:/bamboo/bamboo-home"
		);

		#Update the server config with reverse proxy configuration
		$log->info( "$subname: Updating the reverse proxy configuration in "
			  . $serverConfigFile );
		print "Applying Apache proxy parameters to config...\n\n";
		if ( $globalConfig->param("general.apacheProxy") eq "TRUE" ) {
			updateLineInFile(
				$serverConfigFile,
				"wrapper.app.parameter.2",
				"wrapper.app.parameter.2=webapp/WEB-INF/classes/jetty.xml",
				"wrapper.app.parameter.2"
			);

			updateLineInFile( $serverConfigFile, "wrapper.app.parameter.3",
				"#wrapper.app.parameter.3=../webapp",
				"wrapper.app.parameter.3" );

			updateLineInFile(
				$serverConfigFile,            "wrapper.app.parameter.4",
				"#wrapper.app.parameter.4=/", "wrapper.app.parameter.4"
			);

			updateXMLAttribute(
				$serverJettyConfigFile,
"/Configure/*[\@name='addConnector']/Arg/New/Set[\@name='port']/Property",
				"default",
				$globalConfig->param("$lcApplication.connectorPort")
			);

			updateXMLTextValue(
				$serverJettyConfigFile,
"/Configure/*[\@name='setHandler']/Arg/New/Arg[\@name='contextPath']",
				$globalConfig->param("$lcApplication.appContext")
			);

			createOrUpdateLineInXML(
				$serverJettyConfigFile,
				".*org.eclipse.jetty.server.nio.SelectChannelConnector.*",
				"                <Set name=\"forwarded\">true</Set>\n"
			);

		}

		print "Applying Java memory configuration to install...\n\n";
		$log->info( "$subname: Applying Java memory parameters to "
			  . $javaMemParameterFile );

		updateLineInBambooWrapperConf( $javaMemParameterFile,
			"wrapper.java.additional.", "-Xms",
			$globalConfig->param("$lcApplication.javaMinMemory") );

		updateLineInBambooWrapperConf( $javaMemParameterFile,
			"wrapper.java.additional.", "-Xmx",
			$globalConfig->param("$lcApplication.javaMaxMemory") );

		updateLineInBambooWrapperConf( $javaMemParameterFile,
			"wrapper.java.additional.", "-XX:MaxPermSize=",
			$globalConfig->param("$lcApplication.javaMaxPermSize") );

		@parameterNull = $globalConfig->param("$lcApplication.javaParams");
		if (   ( $#parameterNull == -1 )
			|| $globalConfig->param("$lcApplication.javaParams") eq ""
			|| $globalConfig->param("$lcApplication.javaParams") eq "default" )
		{
			$javaOptsValue = "NOJAVAOPTSCONFIGSPECIFIED";
		}
		else {
			$javaOptsValue = "CONFIGSPECIFIED";
		}

		#Apply the JavaOpts configuration (if any)
		print "Applying Java_Opts configuration to install...\n\n";
		if ( $javaOptsValue ne "NOJAVAOPTSCONFIGSPECIFIED" ) {
			updateLineInBambooWrapperConf(
				$javaMemParameterFile,
				"wrapper.java.additional.",
				$globalConfig->param("$lcApplication.javaParams"),
				$globalConfig->param("$lcApplication.javaParams")
			);
		}

		print "Configuration settings have been applied successfully.\n\n";

		#Run any additional steps
		if ( $globalArch eq "64" ) {
			$WrapperDownloadFile = downloadFileAndChown(
				escapeFilePath(
					$globalConfig->param("$lcApplication.installDir")
				),
				$WrapperDownloadUrlFor64Bit,
				$osUser
			);

			rmtree(
				[
					escapeFilePath(
						$globalConfig->param("$lcApplication.installDir")
					  )
					  . "/wrapper"
				]
			);

			extractAndMoveFile(
				$WrapperDownloadFile,
				escapeFilePath(
					$globalConfig->param("$lcApplication.installDir")
				  )
				  . "/wrapper",
				$osUser, ""
			);
		}

		#Generate the init.d file
		print
"Setting up initd files and run as a service (if configured) please wait...\n\n";
		$log->info("$subname: Generating init.d file for $application.");

		generateInitD(
			$application,
			$osUser,
			escapeFilePath( $globalConfig->param("$lcApplication.installDir") ),
			"bamboo.sh start",
			"bamboo.sh stop",
			$globalConfig->param("$lcApplication.processSearchParameter1"),
			$globalConfig->param("$lcApplication.processSearchParameter2")
		);

	}
	else {

		#Do Install for Bamboo Version 5.1.0 or newer
		$serverXMLFile =
		  escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
		  . "/conf/server.xml";
		$initPropertiesFile =
		    escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
		  . $globalConfig->param("$lcApplication.webappDir")
		  . "/WEB-INF/classes/$lcApplication-init.properties";
		$javaMemParameterFile =
		  escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
		  . "/bin/setenv.sh";

		print "Creating backup of config files...\n\n";
		$log->info("$subname: Backing up config files.");

		backupFile( $serverXMLFile, $osUser );

		backupFile( $initPropertiesFile, $osUser );

		backupFile( $javaMemParameterFile, $osUser );

		print "Applying custom context to $application...\n\n";
		$log->info(
			"$subname: Applying application context to "
			  . escapeFilePath(
				$globalConfig->param("$lcApplication.installDir")
			  )
			  . "/conf/server.xml"
		);

		updateXMLAttribute(
			escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
			  . "/conf/server.xml",
			"//////Context",
			"path",
			getConfigItem( "$lcApplication.appContext", $globalConfig )
		);

		print "Applying port numbers to server config...\n\n";

		#Update the server config with the configured connector port
		$log->info(
			"$subname: Updating the connector port in " . $serverXMLFile );
		updateXMLAttribute( $serverXMLFile, "///Connector", "port",
			$globalConfig->param("$lcApplication.connectorPort") );

		#Update the server config with the configured server port
		$log->info( "$subname: Updating the server port in " . $serverXMLFile );
		updateXMLAttribute( $serverXMLFile, "/Server", "port",
			$globalConfig->param("$lcApplication.serverPort") );

		#Update the server config with reverse proxy configuration
		$log->info( "$subname: Updating the reverse proxy configuration in "
			  . $serverXMLFile );
		print "Applying Apache proxy parameters to config...\n\n";
		if ( $globalConfig->param("general.apacheProxy") eq "TRUE" ) {
			if ( $globalConfig->param("general.apacheProxySingleDomain") eq
				"TRUE" )
			{
				updateXMLAttribute( $serverXMLFile, "///Connector", "proxyName",
					$globalConfig->param("general.apacheProxyHost") );

				if ( $globalConfig->param("general.apacheProxySSL") eq "TRUE" )
				{
					updateXMLAttribute( $serverXMLFile, "///Connector",
						"scheme", "https" );
				}
				else {
					updateXMLAttribute( $serverXMLFile, "///Connector",
						"scheme", "http" );
				}
				updateXMLAttribute( $serverXMLFile, "///Connector", "secure",
					"false" );
				updateXMLAttribute( $serverXMLFile, "///Connector", "proxyPort",
					$globalConfig->param("general.apacheProxyPort") );
			}
			else {
				updateXMLAttribute( $serverXMLFile, "///Connector", "proxyName",
					$globalConfig->param("$lcApplication.apacheProxyHost") );

				if ( $globalConfig->param("$lcApplication.apacheProxySSL") eq
					"TRUE" )
				{
					updateXMLAttribute( $serverXMLFile, "///Connector",
						"scheme", "https" );
				}
				else {
					updateXMLAttribute( $serverXMLFile, "///Connector",
						"scheme", "http" );
				}
				updateXMLAttribute( $serverXMLFile, "///Connector", "secure",
					"false" );
				updateXMLAttribute( $serverXMLFile, "///Connector", "proxyPort",
					$globalConfig->param("$lcApplication.apacheProxyPort") );
			}
		}

		print "Applying home directory location to config...\n\n";

		#Edit Bamboo config file to reference homedir
		$log->info( "$subname: Applying homedir in " . $initPropertiesFile );
		print "Applying home directory to config...\n\n";
		updateLineInFile(
			$initPropertiesFile,
			"bamboo.home",
			"$lcApplication.home="
			  . escapeFilePath(
				$globalConfig->param("$lcApplication.dataDir") ),
			"#bamboo.home=C:/bamboo/bamboo-home"
		);

		@parameterNull = $globalConfig->param("$lcApplication.javaParams");
		if (   ( $#parameterNull == -1 )
			|| $globalConfig->param("$lcApplication.javaParams") eq ""
			|| $globalConfig->param("$lcApplication.javaParams") eq "default" )
		{
			$javaOptsValue = "NOJAVAOPTSCONFIGSPECIFIED";
		}
		else {
			$javaOptsValue = "CONFIGSPECIFIED";
		}

		@parameterNull = $globalConfig->param( $lcApplication . ".tomcatDir" );
		if ( $#parameterNull == -1 ) {
			$tomcatDir = "";
		}
		else {
			$tomcatDir = $globalConfig->param( $lcApplication . ".tomcatDir" );
		}

		#Apply the JavaOpts configuration (if any)
		print "Applying Java_Opts configuration to install...\n\n";
		if ( $javaOptsValue ne "NOJAVAOPTSCONFIGSPECIFIED" ) {
			updateJavaOpts(
				escapeFilePath(
					$globalConfig->param("$lcApplication.installDir")
				  )
				  . $tomcatDir
				  . "/bin/setenv.sh",
				"JAVA_OPTS",
				getConfigItem( "$lcApplication.javaParams", $globalConfig )
			);
		}

		#Apply CATALINA_OPTS to install
		@parameterNull = $globalConfig->param("$lcApplication.catalinaOpts");
		if (   ( $#parameterNull == -1 )
			|| $globalConfig->param("$lcApplication.catalinaOpts") eq ""
			|| $globalConfig->param("$lcApplication.catalinaOpts") eq
			"default" )
		{
			$catalinaOptsValue = "NOCATALINAOPTSCONFIGSPECIFIED";
		}
		else {
			$catalinaOptsValue = "CONFIGSPECIFIED";
		}

		print "Applying CATALINA_OPTS configuration to install...\n\n";
		if ( $javaOptsValue ne "NOCATALINAOPTSCONFIGSPECIFIED" ) {
			updateCatalinaOpts(
				$application,
				escapeFilePath(
					$globalConfig->param("$lcApplication.installDir")
				  )
				  . $tomcatDir
				  . "/bin/setenv.sh",
				"CATALINA_OPTS=",
				getConfigItem( "$lcApplication.catalinaOpts", $globalConfig )
			);
		}

		#Update Java Memory Parameters
		print "Applying Java memory configuration to install...\n\n";
		$log->info( "$subname: Applying Java memory parameters to "
			  . $javaMemParameterFile );

		createOrUpdateLineInFile(
			$javaMemParameterFile,
			"JVM_MINIMUM_MEMORY=",
			"JVM_MINIMUM_MEMORY=" . '"'
			  . $globalConfig->param("$lcApplication.javaMinMemory") . '"',
			"JVM_SUPPORT_RECOMMENDED_ARGS="
		);

		createOrUpdateLineInFile(
			$javaMemParameterFile,
			"JVM_MAXIMUM_MEMORY=",
			"JVM_MAXIMUM_MEMORY=" . '"'
			  . $globalConfig->param("$lcApplication.javaMaxMemory") . '"',
			"JVM_SUPPORT_RECOMMENDED_ARGS="
		);

		createOrUpdateLineInFile(
			$javaMemParameterFile,
			"BAMBOO_MAX_PERM_SIZE=",
			"BAMBOO_MAX_PERM_SIZE=" . '"'
			  . $globalConfig->param("$lcApplication.javaMaxPermSize") . '"',
			"JVM_SUPPORT_RECOMMENDED_ARGS="
		);

		print "Configuration settings have been applied successfully.\n\n";

		#Generate the init.d file
		print
"Setting up initd files and run as a service (if configured) please wait...\n\n";
		$log->info("$subname: Generating init.d file for $application.");

		generateInitD(
			$application,
			$osUser,
			escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
			  . "/bin/",
			"start-bamboo.sh",
			"stop-bamboo.sh",
			$globalConfig->param("$lcApplication.processSearchParameter1"),
			$globalConfig->param("$lcApplication.processSearchParameter2")
		);
	}

	#Finally run generic post install tasks
	postInstallGeneric($application);
}

########################################
#Uninstall Bamboo                      #
########################################
sub uninstallBamboo {
	my $application = "Bamboo";
	uninstallGeneric($application);
}

########################################
#Upgrade Bamboo                        #
########################################
sub upgradeBamboo {
	my $input;
	my $application = "Bamboo";
	my $osUser;
	my $serverConfigFile;
	my $serverJettyConfigFile;
	my $javaMemParameterFile;
	my $lcApplication;
	my $downloadArchivesUrl =
	  "http://www.atlassian.com/software/bamboo/download-archives";
	my $configFile;
	my @requiredConfigItems;
	my $WrapperDownloadFile;
	my @parameterNull;
	my $javaOptsValue;
	my $catalinaOptsValue;
	my $tomcatDir;
	my $WrapperDownloadUrlFor64Bit =
"https://confluence.atlassian.com/download/attachments/289276785/Bamboo_64_Bit_Wrapper.zip?version=1&modificationDate=1346435557878&api=v2";
	my $subname = ( caller(0) )[3];

	#New variables for upgrades above Bamboo version 5.1.0
	my $serverXMLFile;
	my $initPropertiesFile;
	my $serverXLMLFile;

	#End new variables

	$log->debug("BEGIN: $subname");

	#Set up list of config items that are requred for this install to run
	$lcApplication       = lc($application);
	@requiredConfigItems = (
		"bamboo.appContext",              "bamboo.enable",
		"bamboo.dataDir",                 "bamboo.installDir",
		"bamboo.runAsService",            "bamboo.osUser",
		"bamboo.connectorPort",           "bamboo.javaMinMemory",
		"bamboo.javaMaxMemory",           "bamboo.javaMaxPermSize",
		"bamboo.processSearchParameter1", "bamboo.processSearchParameter2",
		"bamboo.crowdIntegration",        "bamboo.serverPort"
	);

	if ( $globalConfig->param("general.apacheProxy") eq "TRUE" ) {
		if (
			$globalConfig->param("general.apacheProxySingleDomain") eq "FALSE" )
		{
			push( @requiredConfigItems, "bamboo.apacheProxyPort" );
			push( @requiredConfigItems, "bamboo.apacheProxySSL" );
			push( @requiredConfigItems, "bamboo.apacheProxyHost" );
		}
	}

	#Force config regeneration if bamboo process search parameter is out of date
	if ( $globalConfig->param("bamboo.processSearchParameter2") ne
		$globalConfig->param("bamboo.installDir") )
	{

#Below we push a completely invalid required config item, it will never exist therefore it will force config generation
		push( @requiredConfigItems,
			"bamboo.thisConfigWillNeverExistThereforeForceConfigGeneration" );
	}

#Check if we are installing version below 5.1.0 to maintain backwards compatibility
	if (
		compareTwoVersions(
			$globalConfig->param("$lcApplication.installedVersion"), "5.1.0" )
		ne "GREATER"
	  )
	{

		#Back up the Crowd configuration files
		if ( $globalConfig->param("$lcApplication.crowdIntegration") eq "TRUE" )
		{
			$log->info("$subname: Backing up Crowd configuration files.");
			print "Backing up the Crowd configuration files...\n\n";
			if ( -e $globalConfig->param("$lcApplication.installDir")
				. "/webapp/WEB-INF/classes/crowd.properties" )
			{
				copyFile(
					$globalConfig->param("$lcApplication.installDir")
					  . "/webapp/WEB-INF/classes/crowd.properties",
					"$Bin/working/crowd.properties.$lcApplication"
				);
			}
			else {
				print
"No crowd.properties currently exists for $application, will not copy.\n\n";
				$log->info(
"$subname: No crowd.properties currently exists for $application, will not copy."
				);
			}
		}
	}
	else {
		if ( $globalConfig->param("$lcApplication.crowdIntegration") eq "TRUE" )
		{
			$log->info("$subname: Backing up Crowd configuration files.");
			print "Backing up the Crowd configuration files...\n\n";
			if ( -e $globalConfig->param("$lcApplication.installDir")
				. "/atlassian-bamboo/WEB-INF/classes/crowd.properties" )
			{
				copyFile(
					$globalConfig->param("$lcApplication.installDir")
					  . "/atlassian-bamboo/WEB-INF/classes/crowd.properties",
					"$Bin/working/crowd.properties.$lcApplication"
				);
			}
			else {
				print
"No crowd.properties currently exists for $application, will not copy.\n\n";
				$log->info(
"$subname: No crowd.properties currently exists for $application, will not copy."
				);
			}
		}
	}

	#Force update config items for search parameters
	$globalConfig->param( "$lcApplication.processSearchParameter1", "java" );
	$globalConfig->param(
		"$lcApplication.processSearchParameter2",
		$globalConfig->param("$lcApplication.installDir")
	);
	$globalConfig->write($configFile);
	loadSuiteConfig();

	#Run generic installer steps
	upgradeGeneric( $application, $downloadArchivesUrl, \@requiredConfigItems );
	$osUser = $globalConfig->param("$lcApplication.osUser")
	  ; #we get this after install in CASE the installer changes the configured user in future

	#Perform application specific configuration
	print "Applying configuration settings to the install, please wait...\n\n";

#Check if we are installing version below 5.1.0 to maintain backwards compatibility
	if (
		compareTwoVersions(
			$globalConfig->param("$lcApplication.installedVersion"), "5.1.0" )
		ne "GREATER"
	  )
	{
		$serverConfigFile =
		  escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
		  . "/conf/wrapper.conf";

		$serverJettyConfigFile =
		  escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
		  . "/webapp/WEB-INF/classes/jetty.xml";

		print "Creating backup of config files...\n\n";
		$log->info("$subname: Backing up config files.");

		backupFile( $serverConfigFile, $osUser );
		backupFile(
			escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
			  . "/webapp/WEB-INF/classes/bamboo-init.properties",
			$osUser
		);
		$javaMemParameterFile =
		  escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
		  . "/conf/wrapper.conf";
		backupFile( $javaMemParameterFile, $osUser );

		print "Applying port numbers to server config...\n\n";

		updateLineInFile(
			$serverConfigFile,
			"wrapper.app.parameter.2",
			"wrapper.app.parameter.2="
			  . $globalConfig->param("$lcApplication.connectorPort"),
			""
		);

		my $bambooContext;
		if ( $globalConfig->param("$lcApplication.appContext") eq "NULL" ) {
			$bambooContext = "/";
		}
		else {
			$bambooContext = $globalConfig->param("$lcApplication.appContext");
		}

		#Apply application context
		updateLineInFile( $serverConfigFile, "wrapper.app.parameter.4",
			"wrapper.app.parameter.4=" . $bambooContext, "" );

		#Edit Bamboo config file to reference homedir
		$log->info(
			"$subname: Applying homedir in "
			  . escapeFilePath(
				$globalConfig->param("$lcApplication.installDir")
			  )
			  . "/webapp/WEB-INF/classes/bamboo-init.properties"
		);
		print "Applying home directory to config...\n\n";
		updateLineInFile(
			escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
			  . "/webapp/WEB-INF/classes/bamboo-init.properties",
			"bamboo.home",
			"$lcApplication.home="
			  . escapeFilePath(
				$globalConfig->param("$lcApplication.dataDir") ),
			"#bamboo.home=C:/bamboo/bamboo-home"
		);

		#Update the server config with reverse proxy configuration
		$log->info( "$subname: Updating the reverse proxy configuration in "
			  . $serverConfigFile );
		print "Applying Apache proxy parameters to config...\n\n";
		if ( $globalConfig->param("general.apacheProxy") eq "TRUE" ) {
			updateLineInFile(
				$serverConfigFile,
				"wrapper.app.parameter.2",
				"wrapper.app.parameter.2=webapp/WEB-INF/classes/jetty.xml",
				"wrapper.app.parameter.2"
			);

			updateLineInFile( $serverConfigFile, "wrapper.app.parameter.3",
				"#wrapper.app.parameter.3=../webapp",
				"wrapper.app.parameter.3" );

			updateLineInFile(
				$serverConfigFile,            "wrapper.app.parameter.4",
				"#wrapper.app.parameter.4=/", "wrapper.app.parameter.4"
			);

			updateXMLAttribute(
				$serverJettyConfigFile,
"/Configure/*[\@name='addConnector']/Arg/New/Set[\@name='port']/Property",
				"default",
				$globalConfig->param("$lcApplication.connectorPort")
			);

			updateXMLTextValue(
				$serverJettyConfigFile,
"/Configure/*[\@name='setHandler']/Arg/New/Arg[\@name='contextPath']",
				$globalConfig->param("$lcApplication.appContext")
			);

			createOrUpdateLineInXML(
				$serverJettyConfigFile,
				".*org.eclipse.jetty.server.nio.SelectChannelConnector.*",
				"                <Set name=\"forwarded\">true</Set>\n"
			);

		}

		print "Applying Java memory configuration to install...\n\n";
		$log->info( "$subname: Applying Java memory parameters to "
			  . $javaMemParameterFile );

		updateLineInBambooWrapperConf( $javaMemParameterFile,
			"wrapper.java.additional.", "-Xms",
			$globalConfig->param("$lcApplication.javaMinMemory") );

		updateLineInBambooWrapperConf( $javaMemParameterFile,
			"wrapper.java.additional.", "-Xmx",
			$globalConfig->param("$lcApplication.javaMaxMemory") );

		updateLineInBambooWrapperConf( $javaMemParameterFile,
			"wrapper.java.additional.", "-XX:MaxPermSize=",
			$globalConfig->param("$lcApplication.javaMaxPermSize") );

		@parameterNull = $globalConfig->param("$lcApplication.javaParams");
		if (   ( $#parameterNull == -1 )
			|| $globalConfig->param("$lcApplication.javaParams") eq ""
			|| $globalConfig->param("$lcApplication.javaParams") eq "default" )
		{
			$javaOptsValue = "NOJAVAOPTSCONFIGSPECIFIED";
		}
		else {
			$javaOptsValue = "CONFIGSPECIFIED";
		}

		#Apply the JavaOpts configuration (if any)
		print "Applying Java_Opts configuration to install...\n\n";
		if ( $javaOptsValue ne "NOJAVAOPTSCONFIGSPECIFIED" ) {
			updateLineInBambooWrapperConf(
				$javaMemParameterFile,
				"wrapper.java.additional.",
				$globalConfig->param("$lcApplication.javaParams"),
				$globalConfig->param("$lcApplication.javaParams")
			);
		}

		print "Configuration settings have been applied successfully.\n\n";

		#Run any additional steps
		if ( $globalArch eq "64" ) {
			$WrapperDownloadFile = downloadFileAndChown(
				escapeFilePath(
					$globalConfig->param("$lcApplication.installDir")
				),
				$WrapperDownloadUrlFor64Bit,
				$osUser
			);

			rmtree(
				[
					escapeFilePath(
						$globalConfig->param("$lcApplication.installDir")
					  )
					  . "/wrapper"
				]
			);

			extractAndMoveFile(
				$WrapperDownloadFile,
				escapeFilePath(
					$globalConfig->param("$lcApplication.installDir")
				  )
				  . "/wrapper",
				$osUser, ""
			);
		}

		#Generate the init.d file
		print
"Setting up initd files and run as a service (if configured) please wait...\n\n";
		$log->info("$subname: Generating init.d file for $application.");

		generateInitD(
			$application,
			$osUser,
			escapeFilePath( $globalConfig->param("$lcApplication.installDir") ),
			"bamboo.sh start",
			"bamboo.sh stop",
			$globalConfig->param("$lcApplication.processSearchParameter1"),
			$globalConfig->param("$lcApplication.processSearchParameter2")
		);

		#Restore the Crowd configuration files
		if ( $globalConfig->param("$lcApplication.crowdIntegration") eq "TRUE" )
		{
			$log->info("$subname: Restoring Crowd configuration files.");
			print "Restoring the Crowd configuration files...\n\n";
			if (
				-e escapeFilePath(
					$globalConfig->param("$lcApplication.installDir")
					  . "/webapp/WEB-INF/classes/crowd.properties"
				)
			  )
			{
				backupFile(
					escapeFilePath(
						$globalConfig->param("$lcApplication.installDir")
						  . "/webapp/WEB-INF/classes/crowd.properties"
					),
					$osUser
				);
			}
			if (
				-e escapeFilePath(
					"$Bin/working/crowd.properties.$lcApplication") )
			{
				copyFile(
					escapeFilePath(
						"$Bin/working/crowd.properties.$lcApplication"),
					escapeFilePath(
						$globalConfig->param("$lcApplication.installDir")
						  . "/webapp/WEB-INF/classes/crowd.properties"
					)
				);

				chownFile(
					$osUser,
					escapeFilePath(
						$globalConfig->param("$lcApplication.installDir")
						  . "/webapp/WEB-INF/classes/crowd.properties"
					)
				);
			}
			else {
				print
"No crowd.properties currently exists for $application that has been backed up, will not restore.\n\n";
				$log->info(
"$subname: No crowd.properties currently exists for $application that has been backed up, will not restore."
				);
			}
		}

		#Restore the Crowd Seraph configuration files
		if ( $globalConfig->param("$lcApplication.crowdIntegration") eq "TRUE" )
		{
			$log->info("$subname: Restoring Crowd Seraph configuration.");
			print "Restoring the Crowd configuration files...\n\n";
			backupFile(
				escapeFilePath(
					$globalConfig->param("$lcApplication.installDir")
					  . "/webapp/WEB-INF/classes/atlassian-user.xml"
				),
				$osUser
			);
			updateSeraphConfig(
				"Bamboo",
				escapeFilePath(
					$globalConfig->param("$lcApplication.installDir")
					  . "/webapp/WEB-INF/classes/atlassian-user.xml"
				),
				"key=\"crowd\"",
				"key=\"hibernateRepository\""
			);
			if ( $globalConfig->param("$lcApplication.crowdSSO") eq "TRUE" ) {
				backupFile(
					escapeFilePath(
						$globalConfig->param("$lcApplication.installDir")
						  . "/webapp/WEB-INF/classes/seraph-config.xml"
					),
					$osUser
				);
				updateSeraphConfig(
					"Bamboo",
					escapeFilePath(
						$globalConfig->param("$lcApplication.installDir")
						  . "/webapp/WEB-INF/classes/seraph-config.xml"
					),
"com.atlassian.crowd.integration.seraph.*BambooAuthenticator",
"com.atlassian.bamboo.user.authentication.BambooAuthenticator"
				);
			}
		}

	}
	else {

		#Do Install for Bamboo Version 5.1.0 or newer
		$serverXMLFile =
		  escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
		  . "/conf/server.xml";
		$initPropertiesFile =
		    escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
		  . $globalConfig->param("$lcApplication.webappDir")
		  . "/WEB-INF/classes/$lcApplication-init.properties";
		$javaMemParameterFile =
		  escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
		  . "/bin/setenv.sh";

		print "Creating backup of config files...\n\n";
		$log->info("$subname: Backing up config files.");

		backupFile( $serverXMLFile, $osUser );

		backupFile( $initPropertiesFile, $osUser );

		backupFile( $javaMemParameterFile, $osUser );

		print "Applying custom context to $application...\n\n";
		$log->info(
			"$subname: Applying application context to "
			  . escapeFilePath(
				$globalConfig->param("$lcApplication.installDir")
			  )
			  . "/conf/server.xml"
		);

		updateXMLAttribute(
			escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
			  . "/conf/server.xml",
			"//////Context",
			"path",
			getConfigItem( "$lcApplication.appContext", $globalConfig )
		);

		print "Applying port numbers to server config...\n\n";

		#Update the server config with the configured connector port
		$log->info(
			"$subname: Updating the connector port in " . $serverXMLFile );
		updateXMLAttribute( $serverXMLFile, "///Connector", "port",
			$globalConfig->param("$lcApplication.connectorPort") );

		#Update the server config with the configured server port
		$log->info( "$subname: Updating the server port in " . $serverXMLFile );
		updateXMLAttribute( $serverXMLFile, "/Server", "port",
			$globalConfig->param("$lcApplication.serverPort") );

		#Update the server config with reverse proxy configuration
		$log->info( "$subname: Updating the reverse proxy configuration in "
			  . $serverXMLFile );
		print "Applying Apache proxy parameters to config...\n\n";
		if ( $globalConfig->param("general.apacheProxy") eq "TRUE" ) {
			if ( $globalConfig->param("general.apacheProxySingleDomain") eq
				"TRUE" )
			{
				updateXMLAttribute( $serverXMLFile, "///Connector", "proxyName",
					$globalConfig->param("general.apacheProxyHost") );

				if ( $globalConfig->param("general.apacheProxySSL") eq "TRUE" )
				{
					updateXMLAttribute( $serverXMLFile, "///Connector",
						"scheme", "https" );
				}
				else {
					updateXMLAttribute( $serverXMLFile, "///Connector",
						"scheme", "http" );
				}
				updateXMLAttribute( $serverXMLFile, "///Connector", "secure",
					"false" );
				updateXMLAttribute( $serverXMLFile, "///Connector", "proxyPort",
					$globalConfig->param("general.apacheProxyPort") );
			}
			else {
				updateXMLAttribute( $serverXMLFile, "///Connector", "proxyName",
					$globalConfig->param("$lcApplication.apacheProxyHost") );

				if ( $globalConfig->param("$lcApplication.apacheProxySSL") eq
					"TRUE" )
				{
					updateXMLAttribute( $serverXMLFile, "///Connector",
						"scheme", "https" );
				}
				else {
					updateXMLAttribute( $serverXMLFile, "///Connector",
						"scheme", "http" );
				}
				updateXMLAttribute( $serverXMLFile, "///Connector", "secure",
					"false" );
				updateXMLAttribute( $serverXMLFile, "///Connector", "proxyPort",
					$globalConfig->param("$lcApplication.apacheProxyPort") );
			}
		}

		print "Applying home directory location to config...\n\n";

		#Edit Bamboo config file to reference homedir
		$log->info( "$subname: Applying homedir in " . $initPropertiesFile );
		print "Applying home directory to config...\n\n";
		updateLineInFile(
			$initPropertiesFile,
			"bamboo.home",
			"$lcApplication.home="
			  . escapeFilePath(
				$globalConfig->param("$lcApplication.dataDir") ),
			"#bamboo.home=C:/bamboo/bamboo-home"
		);

		@parameterNull = $globalConfig->param("$lcApplication.javaParams");
		if (   ( $#parameterNull == -1 )
			|| $globalConfig->param("$lcApplication.javaParams") eq ""
			|| $globalConfig->param("$lcApplication.javaParams") eq "default" )
		{
			$javaOptsValue = "NOJAVAOPTSCONFIGSPECIFIED";
		}
		else {
			$javaOptsValue = "CONFIGSPECIFIED";
		}

		@parameterNull = $globalConfig->param( $lcApplication . ".tomcatDir" );
		if ( $#parameterNull == -1 ) {
			$tomcatDir = "";
		}
		else {
			$tomcatDir = $globalConfig->param( $lcApplication . ".tomcatDir" );
		}

		#Apply the JavaOpts configuration (if any)
		print "Applying Java_Opts configuration to install...\n\n";
		if ( $javaOptsValue ne "NOJAVAOPTSCONFIGSPECIFIED" ) {
			updateJavaOpts(
				escapeFilePath(
					$globalConfig->param("$lcApplication.installDir")
				  )
				  . $tomcatDir
				  . "/bin/setenv.sh",
				"JAVA_OPTS",
				getConfigItem( "$lcApplication.javaParams", $globalConfig )
			);
		}

		#Apply CATALINA_OPTS to install
		@parameterNull = $globalConfig->param("$lcApplication.catalinaOpts");
		if (   ( $#parameterNull == -1 )
			|| $globalConfig->param("$lcApplication.catalinaOpts") eq ""
			|| $globalConfig->param("$lcApplication.catalinaOpts") eq
			"default" )
		{
			$catalinaOptsValue = "NOCATALINAOPTSCONFIGSPECIFIED";
		}
		else {
			$catalinaOptsValue = "CONFIGSPECIFIED";
		}

		print "Applying CATALINA_OPTS configuration to install...\n\n";
		if ( $javaOptsValue ne "NOCATALINAOPTSCONFIGSPECIFIED" ) {
			updateCatalinaOpts(
				$application,
				escapeFilePath(
					$globalConfig->param("$lcApplication.installDir")
				  )
				  . $tomcatDir
				  . "/bin/setenv.sh",
				"CATALINA_OPTS=",
				getConfigItem( "$lcApplication.catalinaOpts", $globalConfig )
			);
		}

		#Update Java Memory Parameters
		print "Applying Java memory configuration to install...\n\n";
		$log->info( "$subname: Applying Java memory parameters to "
			  . $javaMemParameterFile );

		createOrUpdateLineInFile(
			$javaMemParameterFile,
			"JVM_MINIMUM_MEMORY=",
			"JVM_MINIMUM_MEMORY=" . '"'
			  . $globalConfig->param("$lcApplication.javaMinMemory") . '"',
			"JVM_SUPPORT_RECOMMENDED_ARGS="
		);

		createOrUpdateLineInFile(
			$javaMemParameterFile,
			"JVM_MAXIMUM_MEMORY=",
			"JVM_MAXIMUM_MEMORY=" . '"'
			  . $globalConfig->param("$lcApplication.javaMaxMemory") . '"',
			"JVM_SUPPORT_RECOMMENDED_ARGS="
		);

		createOrUpdateLineInFile(
			$javaMemParameterFile,
			"BAMBOO_MAX_PERM_SIZE=",
			"BAMBOO_MAX_PERM_SIZE=" . '"'
			  . $globalConfig->param("$lcApplication.javaMaxPermSize") . '"',
			"JVM_SUPPORT_RECOMMENDED_ARGS="
		);

		print "Configuration settings have been applied successfully.\n\n";

		#Generate the init.d file
		print
"Setting up initd files and run as a service (if configured) please wait...\n\n";
		$log->info("$subname: Generating init.d file for $application.");

		generateInitD(
			$application,
			$osUser,
			escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
			  . "/bin/",
			"start-bamboo.sh",
			"stop-bamboo.sh",
			$globalConfig->param("$lcApplication.processSearchParameter1"),
			$globalConfig->param("$lcApplication.processSearchParameter2")
		);

		#Restore the Crowd configuration files
		if ( $globalConfig->param("$lcApplication.crowdIntegration") eq "TRUE" )
		{
			$log->info("$subname: Restoring Crowd configuration files.");
			print "Restoring the Crowd configuration files...\n\n";
			if (
				-e escapeFilePath(
					    $globalConfig->param("$lcApplication.installDir")
					  . $globalConfig->param("$lcApplication.webappDir")
					  . "/WEB-INF/classes/crowd.properties"
				)
			  )
			{
				backupFile(
					escapeFilePath(
						    $globalConfig->param("$lcApplication.installDir")
						  . $globalConfig->param("$lcApplication.webappDir")
						  . "/WEB-INF/classes/crowd.properties"
					),
					$osUser
				);
			}
			if (
				-e escapeFilePath(
					"$Bin/working/crowd.properties.$lcApplication") )
			{
				copyFile(
					escapeFilePath(
						"$Bin/working/crowd.properties.$lcApplication"),
					escapeFilePath(
						$globalConfig->param("$lcApplication.installDir")
						  . "/atlassian-bamboo/WEB-INF/classes/crowd.properties"
					)
				);

				chownFile(
					$osUser,
					escapeFilePath(
						$globalConfig->param("$lcApplication.installDir")
						  . "/atlassian-bamboo/WEB-INF/classes/crowd.properties"
					)
				);
			}
			else {
				print
"No crowd.properties currently exists for $application that has been backed up, will not restore.\n\n";
				$log->info(
"$subname: No crowd.properties currently exists for $application that has been backed up, will not restore."
				);
			}
		}

		#Restore the Crowd Seraph configuration files
		if ( $globalConfig->param("$lcApplication.crowdIntegration") eq "TRUE" )
		{
			$log->info("$subname: Restoring Crowd Seraph configuration.");
			print "Restoring the Crowd configuration files...\n\n";
			backupFile(
				escapeFilePath(
					    $globalConfig->param("$lcApplication.installDir")
					  . $globalConfig->param("$lcApplication.webappDir")
					  . "/WEB-INF/classes/atlassian-user.xml"
				),
				$osUser
			);
			updateSeraphConfig(
				"Bamboo",
				escapeFilePath(
					    $globalConfig->param("$lcApplication.installDir")
					  . $globalConfig->param("$lcApplication.webappDir")
					  . "/WEB-INF/classes/atlassian-user.xml"
				),
				"key=\"crowd\"",
				"key=\"hibernateRepository\""
			);
			if ( $globalConfig->param("$lcApplication.crowdSSO") eq "TRUE" ) {
				backupFile(
					escapeFilePath(
						    $globalConfig->param("$lcApplication.installDir")
						  . $globalConfig->param("$lcApplication.webappDir")
						  . "/WEB-INF/classes/seraph-config.xml"
					),
					$osUser
				);
				updateSeraphConfig(
					"Bamboo",
					escapeFilePath(
						    $globalConfig->param("$lcApplication.installDir")
						  . $globalConfig->param("$lcApplication.webappDir")
						  . "/WEB-INF/classes/seraph-config.xml"
					),
"com.atlassian.crowd.integration.seraph.*BambooAuthenticator",
"com.atlassian.bamboo.user.authentication.BambooAuthenticator"
				);
			}
		}
	}

	print "Configuration settings have been applied successfully.\n\n";

	#Finally run generic post install tasks
	postUpgradeGeneric($application);
}

#######################################################################
#END BAMBOO MANAGER FUNCTIONS                                         #
#######################################################################

#######################################################################
#BEGIN CONFLUENCE MANAGER FUNCTIONS                                   #
#######################################################################

########################################
#getExistingConfluenceConfig           #
########################################
sub getExistingConfluenceConfig {
	my $cfg;
	my $defaultValue;
	my $application   = "Confluence";
	my $mode          = "CREATE";
	my $lcApplication = lc($application);
	my $subname       = ( caller(0) )[3];
	my $serverConfigFile;
	my $serverSetEnvFile;
	my $externalCrowdInstance;
	my $input;
	my $LOOP  = 0;
	my $LOOP2 = 0;
	my @parameterNull;
	my $returnValue;

	$log->debug("BEGIN: $subname");

	$cfg = $_[0];

	while ( $LOOP == 0 ) {

		#Ask for install dir
		genConfigItem(
			$mode,
			$cfg,
			"$lcApplication.installDir",
"Please enter the directory $application is currently installed into.",
			"",
			'(?!^.*/$)^(/.*)',
"The input you entered was not in the valid format of '/folder'. Please ensure you enter the absolute path with a "
			  . "leading '/' and NO trailing '/'.\n\n"
		);

		if ( -d escapeFilePath( $cfg->param("$lcApplication.installDir") ) ) {
			$LOOP = 1;    #break loop as directory exists
			$log->info( "$subname: Directory "
				  . escapeFilePath( $cfg->param("$lcApplication.installDir") )
				  . " exists. Proceeding..." );
			print "The directory "
			  . escapeFilePath( $cfg->param("$lcApplication.installDir") )
			  . " exists. Proceeding...\n\n";
		}
		else {
			print "The directory "
			  . escapeFilePath( $cfg->param("$lcApplication.installDir") )
			  . " does not exist. Please try again.\n\n";
			$log->info( "The directory "
				  . escapeFilePath( $cfg->param("$lcApplication.installDir") )
				  . " does not exist. Please try again." );
		}
	}

	#Ask for current installed version
	genConfigItem(
		$mode,
		$cfg,
		"$lcApplication.installedVersion",
		"Please enter the version of $application that is currently installed.",
		"",
		'^[0-9]+\.([0-9]+|[0-9]+\.[0-9]+)$',
"The input you entered was not in the valid format of 'x.x.x or x.x' (where x is a version number). Please ensure you enter the version number correctly "
		  . "\n\n"
	);

	genConfigItem(
		$mode,
		$cfg,
		"$lcApplication.javaParams",
"Enter any additional parameters currently added to the JAVA RUN_OPTS for your $application install. Just press enter if you have none.",
		"",
		"",
		""
	);

	genConfigItem(
		$mode,
		$cfg,
		"$lcApplication.catalinaOpts",
"Enter any additional currently added to the Java CATALINA_OPTS for your $application install. Just press enter if you have none.",
		"",
		"",
		""
	);

	if (   $cfg->param("general.apacheProxy") eq "TRUE"
		&& $cfg->param("general.apacheProxySingleDomain") eq "FALSE" )
	{
		genConfigItem(
			$mode,
			$cfg,
			"confluence.apacheProxyHost",
"Please enter the base URL Confluence currently runs on (i.e. the proxyName such as yourdomain.com).",
			"",
			$hostnameRegex,
"The input you entered was not in the valid format of 'yourdomain.com' or 'subdomain.yourdomain.com'. Please try again.\n\n"
		);

		genBooleanConfigItem( $mode, $cfg, "confluence.apacheProxySSL",
			"Do you currently run Confluence over SSL.", "no" );

		genConfigItem(
			$mode,
			$cfg,
			"confluence.apacheProxyPort",
"Please enter the port number that Apache currently serves Confluence on (80 for HTTP, 443 for HTTPS in standard situations).",
			"80",
			'^([0-9]*)$',
"The input you entered was not a valid port number, please try again.\n\n"
		);
	}

	$serverSetEnvFile =
	  escapeFilePath( $cfg->param("$lcApplication.installDir") )
	  . "/bin/setenv.sh";

	$serverConfigFile =
	  escapeFilePath( $cfg->param("$lcApplication.installDir") )
	  . "/conf/server.xml";

	genBooleanConfigItem(
		$mode,
		$cfg,
		"$lcApplication.runAsService",
"Does your $application instance run as a service (i.e. runs on boot)? yes/no.",
		"yes"
	);

	print
"Please wait, attempting to get the $application data/home directory from it's config files...\n\n";
	$log->info(
"$subname: Attempting to get $application data directory from config file $serverConfigFile."
	);

	@parameterNull = $cfg->param("general.externalCrowdInstance");

	if ( $#parameterNull == -1 ) {
		$externalCrowdInstance = "FALSE";
	}
	else {
		$externalCrowdInstance = $cfg->param("general.externalCrowdInstance");
	}

	if (   $externalCrowdInstance eq "TRUE"
		|| $cfg->param("crowd.enable") eq "TRUE" )
	{
		genBooleanConfigItem(
			$mode,
			$cfg,
			"confluence.crowdIntegration",
"Will you be using Crowd as the authentication backend for Confluence? yes/no.",
			"yes"
		);

		if ( $cfg->param("confluence.crowdIntegration") eq "TRUE" ) {
			genBooleanConfigItem( $mode, $cfg, "confluence.crowdSSO",
				"Will you be using Crowd for Single Sign On (SSO)? yes/no.",
				"yes" );
		}
	}
	else {
		$cfg->param( "confluence.crowdIntegration", "FALSE" );
		$cfg->param( "confluence.crowdSSO",         "FALSE" );
	}

	#get data/home directory
	$returnValue = getLineFromFile(
		escapeFilePath( $cfg->param("$lcApplication.installDir") )
		  . "/confluence/WEB-INF/classes/confluence-init.properties",
		"confluence.home\\s?=", ".*=\\s?(.*)"
	);

	if ( $returnValue eq "NOTFOUND" ) {
		$log->info(
"$subname: Unable to locate $application data directory. Asking user for input."
		);
		genConfigItem(
			$mode,
			$cfg,
			"$lcApplication.dataDir",
"Unable to find the data directory in the expected location in the $application config. Please enter the directory $application"
			  . "'s data is *currently* stored in.",
			"",
			'(?!^.*/$)^(/.*)',
"The input you entered was not in the valid format of '/folder'. Please ensure you enter the absolute path with a "
			  . "leading '/' and NO trailing '/'.\n\n"
		);
	}
	else {
		$cfg->param( "$lcApplication.dataDir", $returnValue );
		print
"$application data directory has been found successfully and added to the config file...\n\n";
		$log->info(
			"$subname: $application data directory found and added to config."
		);
	}

	#getContextFromFile
	$returnValue = "";

	print
"Please wait, attempting to get the $application context from it's config files...\n\n";
	$log->info(
"$subname: Attempting to get $application context from config file $serverConfigFile."
	);
	$returnValue =
	  getXMLAttribute( $serverConfigFile, "//////Context", "path" );

	if ( $returnValue eq "NOTFOUND" ) {
		$log->info(
"$subname: Unable to locate $application context. Asking user for input."
		);
		genConfigItem(
			$mode,
			$cfg,
			"$lcApplication.appContext",
"Unable to find the context in the expected location in the $application config. Please enter the context that $application currently runs under (i.e. /confluence or /wiki). Write NULL to blank out the context.",
			"/confluence",
			'(?!^.*/$)^(/.*)',
"The input you entered was not in the valid format of '/folder'. Please ensure you enter the path with a "
			  . "leading '/' and NO trailing '/'.\n\n"
		);
	}
	else {
		if ( $returnValue eq "" ) {
			$returnValue = "NULL";
		}
		$cfg->param( "$lcApplication.appContext", $returnValue );
		print
"$application context has been found successfully and added to the config file...\n\n";
		$log->info("$subname: $application context found and added to config.");
	}

	$returnValue = "";

	print
"Please wait, attempting to get the $application connectorPort from it's config files...\n\n";
	$log->info(
"$subname: Attempting to get $application connectorPort from config file $serverConfigFile."
	);

	#Get connector port from file
	$returnValue = getXMLAttribute( $serverConfigFile, "///Connector", "port" );

	if ( $returnValue eq "NOTFOUND" ) {
		$log->info(
"$subname: Unable to locate $application connectorPort. Asking user for input."
		);
		genConfigItem(
			$mode,
			$cfg,
			"$lcApplication.connectorPort",
"Unable to find the connector port in the expected location in the $application config. Please enter the Connector port $application *currently* runs on (note this is the port you will access in the browser).",
			"8090",
			'^([0-9]*)$',
"The port number you entered contained invalid characters. Please ensure you enter only digits.\n\n"
		);
	}
	else {
		$cfg->param( "$lcApplication.connectorPort", $returnValue );
		print
"$application connectorPort has been found successfully and added to the config file...\n\n";
		$log->info(
			"$subname: $application connectorPort found and added to config.");
	}

	$returnValue = "";

	print
"Please wait, attempting to get the $application serverPort from it's config files...\n\n";
	$log->info(
"$subname: Attempting to get $application serverPort from config file $serverConfigFile."
	);

	#Get connector port from file
	$returnValue = getXMLAttribute( $serverConfigFile, "/Server", "port" );

	if ( $returnValue eq "NOTFOUND" ) {
		$log->info(
"$subname: Unable to locate $application serverPort. Asking user for input."
		);
		genConfigItem(
			$mode,
			$cfg,
			"$lcApplication.serverPort",
"Unable to find the server port in the expected location in the $application config. Please enter the Server port $application *currently* runs on (note this is the tomcat control port).",
			"8000",
			'^([0-9]*)$',
"The port number you entered contained invalid characters. Please ensure you enter only digits.\n\n"
		);
	}
	else {
		$cfg->param( "$lcApplication.serverPort", $returnValue );
		print
"$application serverPort has been found successfully and added to the config file...\n\n";
		$log->info(
			"$subname: $application serverPort found and added to config.");
	}

	$returnValue = "";

	print
"Please wait, attempting to get the $application Xms java memory parameter from it's config files...\n\n";
	$log->info(
"$subname: Attempting to get $application Xms java memory parameter from config file $serverConfigFile."
	);
	$returnValue =
	  getJavaMemParameter( $serverSetEnvFile, "JAVA_OPTS", "-Xms" );
	if ( $returnValue eq "NOTFOUND" ) {
		$log->info(
"$subname: Unable to locate $application Xms memory parameter. Asking user for input."
		);
		genConfigItem(
			$mode,
			$cfg,
			"$lcApplication.javaMinMemory",
"Unable to find the java Xms memory parameter in the expected location in the $application config. Please enter the minimum amount of memory *currently* assigned to $application.",
			"256m",
			'^([0-9]*m)$',
"The memory value you entered is in an invalid format. Please ensure you use the format '1234m'. (i.e. '256m')"
		);
	}
	else {
		$cfg->param( "$lcApplication.javaMinMemory", $returnValue );
		print
"$application Xms java memory parameter has been found successfully and added to the config file...\n\n";
		$log->info(
"$subname: $application Xms java memory parameter found and added to config."
		);
	}

	$returnValue = "";

	print
"Please wait, attempting to get the $application Xmx java memory parameter from it's config files...\n\n";
	$log->info(
"$subname: Attempting to get $application Xmx java memory parameter from config file $serverConfigFile."
	);
	$returnValue =
	  getJavaMemParameter( $serverSetEnvFile, "JAVA_OPTS", "-Xmx" );
	if ( $returnValue eq "NOTFOUND" ) {
		$log->info(
"$subname: Unable to locate $application Xmx memory parameter. Asking user for input."
		);
		genConfigItem(
			$mode,
			$cfg,
			"$lcApplication.javaMaxMemory",
"Unable to find the java Xmx memory parameter in the expected location in the $application config. Please enter the maximum amount of memory *currently* assigned to $application.",
			"512m",
			'^([0-9]*m)$',
"The memory value you entered is in an invalid format. Please ensure you use the format '1234m'. (i.e. '256m')"
		);
	}
	else {
		$cfg->param( "$lcApplication.javaMaxMemory", $returnValue );
		print
"$application Xmx java memory parameter has been found successfully and added to the config file...\n\n";
		$log->info(
"$subname: $application Xmx java memory parameter found and added to config."
		);
	}

	$returnValue = "";

	print
"Please wait, attempting to get the $application XX:MaxPermSize java memory parameter from it's config files...\n\n";
	$log->info(
"$subname: Attempting to get $application XX:MaxPermSize java memory parameter from config file $serverConfigFile."
	);
	$returnValue =
	  getJavaMemParameter( $serverSetEnvFile, "JAVA_OPTS", "-XX:MaxPermSize=" );
	if ( $returnValue eq "NOTFOUND" ) {
		$log->info(
"$subname: Unable to locate $application XX:MaxPermSize memory parameter. Asking user for input."
		);
		genConfigItem(
			$mode,
			$cfg,
			"$lcApplication.javaMaxPermSize",
"Unable to find the java XX:MaxPermSize memory parameter in the expected location in the $application config. Please enter the maximum amount of permGen memory *currently* assigned to $application.",
			"256m",
			'^([0-9]*m)$',
"The memory value you entered is in an invalid format. Please ensure you use the format '1234m'. (i.e. '256m')"
		);
	}
	else {
		$cfg->param( "$lcApplication.javaMaxPermSize", $returnValue );
		print
"$application XX:MaxPermSize java memory parameter has been found successfully and added to the config file...\n\n";
		$log->info(
"$subname: $application XX:MaxPermSize java memory parameter found and added to config."
		);
	}

	$returnValue = "";

	#getOSuser
	open( my $inputFileHandle,
		'<', escapeFilePath( $cfg->param("$lcApplication.installDir") ) )
	  or $log->logdie(
"Unable to open install dir for $application to test who owns it. Really this should never happen as we have already tested that the directory exists."
	  );
	my (
		$dev,   $ino,     $fileMode, $nlink, $uid,
		$gid,   $rdev,    $size,     $atime, $mtime,
		$ctime, $blksize, $blocks
	) = stat($inputFileHandle);
	$returnValue = getpwuid($uid);

	close $inputFileHandle;

	#confirmWithUserThatIsTheCorrectOSUser
	$input = getBooleanInput(
"We have detected that the user $application runs under is '$returnValue'. Is this correct? yes/no [yes]: "
	);
	print "\n";
	if ( $input eq "default" || $input eq "yes" ) {
		$cfg->param( "$lcApplication.osUser", $returnValue );
		print
		  "The osUser $returnValue has been added to the config file...\n\n";
		$log->info(
"$subname: User confirmed that the user $application runs under is $returnValue. This has been added to the config."
		);
	}
	else {
		genConfigItem(
			$mode,
			$cfg,
			"$lcApplication.osUser",
"In that case please enter the user that $application *currently* runs under.",
			"",
			'^([a-zA-Z0-9]*)$',
"The user you entered was in an invalid format. Please ensure you enter only letters and numbers without any spaces or other characters.\n\n"
		);
	}

	if (   $cfg->param("general.apacheProxy") eq "TRUE"
		&& $cfg->param("general.apacheProxySingleDomain") eq "FALSE" )
	{
		$returnValue = "";

		print
"Please wait, attempting to get the Apache proxy base hostname configuration for $application from the configuration files...\n\n";
		$log->info(
"$subname: Attempting to get $application proxyName from config file $serverConfigFile."
		);
		$returnValue =
		  getXMLAttribute( $serverConfigFile, "///Connector", "proxyName" );

		if ( $returnValue eq "NOTFOUND" ) {
			$log->info(
"$subname: Unable to locate $application proxyName. Asking user for input."
			);
			genConfigItem(
				$mode,
				$cfg,
				"$lcApplication.apacheProxyHost",
"Unable to find the base hostname attribute in the expected location in the $application config. Please enter the base URL that will be serving the site (i.e. the proxyName such as yourdomain.com).",
				"",
				$hostnameRegex,
"The input you entered was not in the valid format of 'yourdomain.com' or 'subdomain.yourdomain.com'. Please try again.\n\n"
			);
		}
		else {
			$cfg->param( "$lcApplication.apacheProxyHost", $returnValue );
			print
"$application base hostname has been found successfully and added to the config file...\n\n";
			$log->info(
"$subname: $application base hostname found and added to config."
			);
		}

		$returnValue = "";

		print
"Please wait, attempting to get the Apache proxy scheme configuration for $application from the configuration files...\n\n";
		$log->info(
"$subname: Attempting to get $application proxy scheme from config file $serverConfigFile."
		);
		$returnValue =
		  getXMLAttribute( $serverConfigFile, "///Connector", "scheme" );

		if ( $returnValue eq "NOTFOUND" ) {
			$log->info(
"$subname: Unable to locate $application proxy scheme. Asking user for input."
			);
			genBooleanConfigItem(
				$mode,
				$cfg,
				"$lcApplication.apacheProxySSL",
"Unable to locate the Apache proxy scheme configuration in $application config. Will you be running $application over SSL.",
				"no"
			);
		}
		else {
			if ( $returnValue eq "http" ) {
				$log->info(
"$subname: return value for Apache Proxy Scheme config is 'http'."
				);
				$cfg->param( "$lcApplication.apacheProxySSL", "FALSE" );
			}
			elsif ( $returnValue eq "https" ) {
				$log->info(
"$subname: return value for Apache Proxy Scheme config is 'http'."
				);
				$cfg->param( "$lcApplication.apacheProxySSL", "TRUE" );
			}
			else {
				$log->info(
"$subname: return value for Apache Proxy Scheme config is 'UNKNOWN' This is not good."
				);
				$cfg->param( "$lcApplication.apacheProxySSL", "UNKNOWN" );
			}

			print
"$application Apache Proxy scheme has been found successfully and added to the config file...\n\n";
			$log->info(
				"$subname: $application proxy scheme found and added to config."
			);
		}

		$returnValue = "";

		print
"Please wait, attempting to get the Apache proxy port configuration for $application from the configuration files...\n\n";
		$log->info(
"$subname: Attempting to get $application proxyPort from config file $serverConfigFile."
		);
		$returnValue =
		  getXMLAttribute( $serverConfigFile, "///Connector", "proxyPort" );

		if ( $returnValue eq "NOTFOUND" ) {
			$log->info(
"$subname: Unable to locate $application proxyPort. Asking user for input."
			);
			genConfigItem(
				$mode,
				$cfg,
				"$lcApplication.apacheProxyPort",
"Unable to find the Apache proxy port attribute in the expected location in the $application config. Please enter the port number that Apache currently serves on (80 for HTTP, 443 for HTTPS in standard situations).",
				"80/443",
				'^([0-9]*)$',
"The input you entered was not a valid port number, please try again.\n\n"
			);
		}
		else {
			$cfg->param( "$lcApplication.apacheProxyPort", $returnValue );
			print
"$application base hostname has been found successfully and added to the config file...\n\n";
			$log->info(
"$subname: $application base hostname found and added to config."
			);
		}
	}

	#Set up some defaults for Confluence
	$cfg->param( "confluence.processSearchParameter1", "java" );
	$cfg->param( "confluence.processSearchParameter2",
		"classpath " . $cfg->param("confluence.installDir") );
	$cfg->param( "$lcApplication.enable", "TRUE" );

	$cfg->write($configFile);
	loadSuiteConfig();

	print
"We now have the $application config and it has been written to the config file. Please press enter to continue.\n";
	$input = <STDIN>;
}

########################################
#GenerateConfluenceConfig              #
########################################
sub generateConfluenceConfig {
	my $cfg;
	my $mode;
	my $defaultValue;
	my @parameterNull;
	my $externalCrowdInstance;
	my $application = "Confluence";
	my $subname     = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	$mode = $_[0];
	$cfg  = $_[1];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_mode", $mode );

	genConfigItem(
		$mode,
		$cfg,
		"confluence.installDir",
		"Please enter the directory Confluence will be installed into.",
		$cfg->param("general.rootInstallDir") . "/confluence",
		'(?!^.*/$)^(/.*)',
"The input you entered was not in the valid format of '/folder'. Please ensure you enter the absolute path with a "
		  . "leading '/' and NO trailing '/'.\n\n"
	);
	genConfigItem(
		$mode,
		$cfg,
		"confluence.dataDir",
		"Please enter the directory Confluence's data will be stored in.",
		$cfg->param("general.rootDataDir") . "/confluence",
		'(?!^.*/$)^(/.*)',
"The input you entered was not in the valid format of '/folder'. Please ensure you enter the absolute path with a "
		  . "leading '/' and NO trailing '/'.\n\n"
	);

	genConfigItem(
		$mode,
		$cfg,
		"confluence.osUser",
		"Enter the user that Confluence will run under.",
		"confluence",
		'^([a-zA-Z0-9]*)$',
"The user you entered was in an invalid format. Please ensure you enter only letters and numbers without any spaces or other characters.\n\n"
	);

	genConfigItem(
		$mode,
		$cfg,
		"confluence.appContext",
"Enter the context that Confluence should run under (i.e. /wiki or /confluence). Write NULL to blank out the context.",
		"/confluence",
		'(?!^.*/$)^(/.*)',
"The input you entered was not in the valid format of '/folder'. Please ensure you enter the path with a "
		  . "leading '/' and NO trailing '/'.\n\n"
	);
	genConfigItem(
		$mode,
		$cfg,
		"confluence.connectorPort",
"Please enter the Connector port Confluence will run on (note this is the port you will access in the browser).",
		"8090",
		'^([0-9]*)$',
"The port number you entered contained invalid characters. Please ensure you enter only digits.\n\n"
	);
	checkConfiguredPort( $application, "confluence.connectorPort", $cfg );

	genConfigItem(
		$mode,
		$cfg,
		"confluence.serverPort",
"Please enter the SERVER port Confluence will run on (note this is the control port not the port you access in a browser).",
		"8000",
		'^([0-9]*)$',
"The port number you entered contained invalid characters. Please ensure you enter only digits.\n\n"
	);

	checkConfiguredPort( $application, "confluence.serverPort", $cfg );

	genConfigItem(
		$mode,
		$cfg,
		"confluence.javaParams",
"Enter any additional parameters you would like to add to the Java RUN_OPTS.",
		"",
		"",
		""
	);

	genConfigItem(
		$mode,
		$cfg,
		"confluence.catalinaOpts",
"Enter any additional parameters you would like to add to the Java CATALINA_OPTS.",
		"",
		"",
		""
	);

	genConfigItem(
		$mode,
		$cfg,
		"confluence.javaMinMemory",
"Enter the minimum amount of memory you would like to assign to Confluence.",
		"256m",
		'^([0-9]*m)$',
"The memory value you entered is in an invalid format. Please ensure you use the format '1234m'. (i.e. '256m')"
	);

	genConfigItem(
		$mode,
		$cfg,
		"confluence.javaMaxMemory",
"Enter the maximum amount of memory you would like to assign to Confluence.",
		"512m",
		'^([0-9]*m)$',
"The memory value you entered is in an invalid format. Please ensure you use the format '1234m'. (i.e. '256m')"
	);

	genConfigItem(
		$mode,
		$cfg,
		"confluence.javaMaxPermSize",
"Enter the amount of memory for the MAX_PERM_SIZE parameter that you would like to assign to Confluence.",
		"256m",
		'^([0-9]*m)$',
"The memory value you entered is in an invalid format. Please ensure you use the format '1234m'. (i.e. '256m')"
	);

	if (   $cfg->param("general.apacheProxy") eq "TRUE"
		&& $cfg->param("general.apacheProxySingleDomain") eq "FALSE" )
	{
		genConfigItem(
			$mode,
			$cfg,
			"confluence.apacheProxyHost",
"Please enter the base URL that will be serving the site (i.e. the proxyName such as yourdomain.com).",
			"",
			$hostnameRegex,
"The input you entered was not in the valid format of 'yourdomain.com' or 'subdomain.yourdomain.com'. Please try again.\n\n"
		);

		genBooleanConfigItem( $mode, $cfg, "confluence.apacheProxySSL",
			"Will you be running Confluence over SSL.", "no" );

		genConfigItem(
			$mode,
			$cfg,
			"confluence.apacheProxyPort",
"Please enter the port number that Apache will serve on (80 for HTTP, 443 for HTTPS in standard situations).",
			"80",
			'^([0-9]*)$',
"The input you entered was not a valid port number, please try again.\n\n"
		);
	}

	genBooleanConfigItem( $mode, $cfg, "confluence.runAsService",
		"Would you like to run Confluence as a service? yes/no.", "yes" );

	@parameterNull = $cfg->param("general.externalCrowdInstance");

	if ( $#parameterNull == -1 ) {
		$externalCrowdInstance = "FALSE";
	}
	else {
		$externalCrowdInstance = $cfg->param("general.externalCrowdInstance");
	}

	if (   $externalCrowdInstance eq "TRUE"
		|| $cfg->param("crowd.enable") eq "TRUE" )
	{
		genBooleanConfigItem(
			$mode,
			$cfg,
			"confluence.crowdIntegration",
"Will you be using Crowd as the authentication backend for Confluence? yes/no.",
			"yes"
		);

		if ( $cfg->param("confluence.crowdIntegration") eq "TRUE" ) {
			genBooleanConfigItem( $mode, $cfg, "confluence.crowdSSO",
				"Will you be using Crowd for Single Sign On (SSO)? yes/no.",
				"yes" );
		}
	}
	else {
		$cfg->param( "confluence.crowdIntegration", "FALSE" );
		$cfg->param( "confluence.crowdSSO",         "FALSE" );
	}

	#Set up some defaults for Confluence
	$cfg->param( "confluence.processSearchParameter1", "java" );
	$cfg->param( "confluence.processSearchParameter2",
		"classpath " . $cfg->param("confluence.installDir") );

	$cfg->param( "confluence.enable", "TRUE" );

}

########################################
#Install Confluence                    #
########################################
sub installConfluence {
	my $serverXMLFile;
	my $initPropertiesFile;
	my @parameterNull;
	my $javaOptsValue;
	my $catalinaOptsValue;
	my $application   = "Confluence";
	my $lcApplication = lc($application);
	my $javaMemParameterFile;
	my $osUser;
	my $jdbcJAR;
	my $needJDBC;
	my $input;
	my $javaParameterName;
	my $downloadArchivesUrl =
	  "http://www.atlassian.com/software/confluence/download-archives";
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	#Set up list of config items that are requred for this install to run
	my @requiredConfigItems;
	@requiredConfigItems = (
		"confluence.appContext",
		"confluence.enable",
		"confluence.dataDir",
		"confluence.installDir",
		"confluence.runAsService",
		"confluence.serverPort",
		"confluence.connectorPort",
		"confluence.javaMinMemory",
		"confluence.javaMaxMemory",
		"confluence.javaMaxPermSize",
		"confluence.processSearchParameter1",
		"confluence.processSearchParameter2",
		"confluence.crowdIntegration",
		"confluence.osUser"
	);

	if ( $globalConfig->param("general.apacheProxy") eq "TRUE" ) {
		if (
			$globalConfig->param("general.apacheProxySingleDomain") eq "FALSE" )
		{
			push( @requiredConfigItems, "confluence.apacheProxyPort" );
			push( @requiredConfigItems, "confluence.apacheProxySSL" );
			push( @requiredConfigItems, "confluence.apacheProxyHost" );
		}
	}

	#Run generic installer steps
	installGeneric( $application, $downloadArchivesUrl, \@requiredConfigItems );
	$osUser = $globalConfig->param("$lcApplication.osUser")
	  ; #we get this after install in CASE the installer changes the configured user in future

	#Force update config items for search parameters
	$globalConfig->param( "$lcApplication.processSearchParameter1", "java" );
	$globalConfig->param( "$lcApplication.processSearchParameter2",
		"classpath " . $globalConfig->param("$lcApplication.installDir") );
	$globalConfig->write($configFile);
	loadSuiteConfig();

	#Perform application specific configuration
	print "Applying configuration settings to the install, please wait...\n\n";

	$serverXMLFile =
	  escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
	  . "/conf/server.xml";

	$initPropertiesFile =
	  escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
	  . "/confluence/WEB-INF/classes/$lcApplication-init.properties";
	$javaMemParameterFile =
	  escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
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

	#Update the server config with reverse proxy configuration
	$log->info( "$subname: Updating the reverse proxy configuration in "
		  . $serverXMLFile );
	print "Applying Apache proxy parameters to config...\n\n";
	if ( $globalConfig->param("general.apacheProxy") eq "TRUE" ) {
		if ( $globalConfig->param("general.apacheProxySingleDomain") eq "TRUE" )
		{
			updateXMLAttribute( $serverXMLFile, "///Connector", "proxyName",
				$globalConfig->param("general.apacheProxyHost") );

			if ( $globalConfig->param("general.apacheProxySSL") eq "TRUE" ) {
				updateXMLAttribute( $serverXMLFile, "///Connector", "scheme",
					"https" );
			}
			else {
				updateXMLAttribute( $serverXMLFile, "///Connector", "scheme",
					"http" );
			}
			updateXMLAttribute( $serverXMLFile, "///Connector", "secure",
				"false" );
			updateXMLAttribute( $serverXMLFile, "///Connector", "proxyPort",
				$globalConfig->param("general.apacheProxyPort") );
		}
		else {
			updateXMLAttribute( $serverXMLFile, "///Connector", "proxyName",
				$globalConfig->param("$lcApplication.apacheProxyHost") );
			if ( $globalConfig->param("$lcApplication.apacheProxySSL") eq
				"TRUE" )
			{
				updateXMLAttribute( $serverXMLFile, "///Connector", "scheme",
					"https" );
			}
			else {
				updateXMLAttribute( $serverXMLFile, "///Connector", "scheme",
					"http" );
			}
			updateXMLAttribute( $serverXMLFile, "///Connector", "secure",
				"false" );
			updateXMLAttribute( $serverXMLFile, "///Connector", "proxyPort",
				$globalConfig->param("$lcApplication.apacheProxyPort") );
		}
	}

	#Edit Confluence config file to reference homedir
	$log->info( "$subname: Applying homedir in " . $initPropertiesFile );
	print "Applying home directory to config...\n\n";
	updateLineInFile(
		$initPropertiesFile,
		"confluence.home=",
		"confluence.home="
		  . escapeFilePath( $globalConfig->param("$lcApplication.dataDir") ),
		"# confluence.home="
	);

	@parameterNull = $globalConfig->param("$lcApplication.javaParams");
	if (   ( $#parameterNull == -1 )
		|| $globalConfig->param("$lcApplication.javaParams") eq ""
		|| $globalConfig->param("$lcApplication.javaParams") eq "default" )
	{
		$javaOptsValue = "NOJAVAOPTSCONFIGSPECIFIED";
	}
	else {
		$javaOptsValue = "CONFIGSPECIFIED";
	}

#Check if we are installing version below 5.6 to maintain backwards compatibility
	if (
		compareTwoVersions(
			$globalConfig->param("$lcApplication.installedVersion"), "5.5.6" )
		ne "GREATER"
	  )
	{
		$javaParameterName = "JAVA_OPTS";
	}
	else {

	   #newer than 5.5.6 - As of 5.6 Confluence uses CATALINA_OPTS not JAVA_OPTS
		$javaParameterName = "CATALINA_OPTS";
	}

	#Apply the JavaOpts configuration (if any)
	print "Applying Java_Opts configuration to install...\n\n";
	if ( $javaOptsValue ne "NOJAVAOPTSCONFIGSPECIFIED" ) {
		updateJavaOpts(
			escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
			  . "/bin/setenv.sh",
			$javaParameterName,
			getConfigItem( "$lcApplication.javaParams", $globalConfig )
		);
	}

	#Apply Catalina Opts to Install
	@parameterNull = $globalConfig->param("$lcApplication.catalinaOpts");
	if (   ( $#parameterNull == -1 )
		|| $globalConfig->param("$lcApplication.catalinaOpts") eq ""
		|| $globalConfig->param("$lcApplication.catalinaOpts") eq "default" )
	{
		$catalinaOptsValue = "NOCATALINAOPTSCONFIGSPECIFIED";
	}
	else {
		$catalinaOptsValue = "CONFIGSPECIFIED";
	}

	print "Applying CATALINA_OPTS configuration to install...\n\n";
	if ( $javaOptsValue ne "NOCATALINAOPTSCONFIGSPECIFIED" ) {
		updateCatalinaOpts(
			$application,
			escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
			  . "/bin/setenv.sh",
			"CATALINA_OPTS=",
			getConfigItem( "$lcApplication.catalinaOpts", $globalConfig )
		);
	}

	print "Configuration settings have been applied successfully.\n\n";

	#Run any additional steps

#Check if we are installing version below 5.6 to maintain backwards compatibility
	if (
		compareTwoVersions(
			$globalConfig->param("$lcApplication.installedVersion"), "5.5.6" )
		ne "GREATER"
	  )
	{
		$javaParameterName = "JAVA_OPTS";
	}
	else {

	   #newer than 5.5.6 - As of 5.6 Confluence uses CATALINA_OPTS not JAVA_OPTS
		$javaParameterName = "CATALINA_OPTS";
	}

	#Update Java Memory Parameters
	print "Applying Java memory configuration to install...\n\n";
	$log->info( "$subname: Applying Java memory parameters to "
		  . $javaMemParameterFile );
	updateJavaMemParameter( $javaMemParameterFile, $javaParameterName, "-Xms",
		$globalConfig->param("$lcApplication.javaMinMemory") );
	updateJavaMemParameter( $javaMemParameterFile, $javaParameterName, "-Xmx",
		$globalConfig->param("$lcApplication.javaMaxMemory") );
	updateJavaMemParameter( $javaMemParameterFile, $javaParameterName,
		"-XX:MaxPermSize=",
		$globalConfig->param("$lcApplication.javaMaxPermSize") );

#If Oracle is the Database, Confluence does not come with the driver so check for it and copy if we need it

	@parameterNull = $globalConfig->param("general.dbJDBCJar");
	if ( ( $#parameterNull == -1 ) ) {
		$jdbcJAR = "";
		$log->info("$subname: JDBC undefined in settings.cnf");
	}
	else {
		$jdbcJAR = $globalConfig->param("general.dbJDBCJar");
		$log->info("$subname: JDBC is defined in settings.cnf as $jdbcJAR");
	}

	if ( $globalConfig->param("general.targetDBType") eq "Oracle" ) {
		if ( $lcApplication eq "confluence" ) {
			print
"Database is configured as Oracle, copying the JDBC connector to $application install if needed.\n\n";
			if (
				-e escapeFilePath(
					$globalConfig->param("$lcApplication.installDir")
				)
				. "/lib/ojdbc6.jar"
				|| -e escapeFilePath(
					$globalConfig->param("$lcApplication.installDir")
				)
				. "/confluence/WEB-INF/lib/ojdbc6.jar"
			  )
			{
				$needJDBC = "FALSE";
				$log->info(
"$subname: JDBC already exists in $application lib directories"
				);
			}
			else {
				$needJDBC = "TRUE";
				$log->info(
"$subname: JDBC does not exist in $application lib directories"
				);
			}
		}

		if ( $needJDBC eq "TRUE" && $jdbcJAR ne "" ) {
			$log->info(
				"$subname: Copying Oracle JDBC to $application lib directory");
			copyFile(
				$globalConfig->param("general.dbJDBCJar"),
				escapeFilePath(
					$globalConfig->param("$lcApplication.installDir")
				  )
				  . "/lib/"
			);

			#Chown the files again
			$log->info(
				"$subname: Chowning "
				  . escapeFilePath(
					$globalConfig->param("$lcApplication.installDir")
				  )
				  . "/lib/"
				  . " to $osUser following Oracle JDBC install."
			);
			chownRecursive(
				$osUser,
				escapeFilePath(
					$globalConfig->param("$lcApplication.installDir")
				  )
				  . "/lib/"
			);

		}
		elsif ( $needJDBC eq "FALSE" ) {
			$log->info(
"$subname: $application already has ojdbc6.jar, no need to copy. "
			);
		}
		elsif ( $needJDBC eq "TRUE" && $jdbcJAR eq "" ) {
			$log->info(
"$subname: JDBC needed for Oracle but none defined in settings.cnf. Warning user."
			);
			print
"It appears we need the ojdb6.jar file but you have not set a path to it in settings.cnf. Therefore you will need to manually copy the ojdbc6.jar file to the $application lib directory manually before it will work. Please press enter to continue...";
			$input = <STDIN>;
		}
	}

	#Generate the init.d file
	print
"Setting up initd files and run as a service (if configured) please wait...\n\n";
	$log->info("$subname: Generating init.d file for $application.");

	generateInitD(
		$application,
		$osUser,
		escapeFilePath( $globalConfig->param("$lcApplication.installDir") ),
		"/bin/start-confluence.sh",
		"/bin/stop-confluence.sh",
		$globalConfig->param("$lcApplication.processSearchParameter1"),
		$globalConfig->param("$lcApplication.processSearchParameter2")
	);

	#Finally run generic post install tasks
	postInstallGeneric($application);
}

########################################
#Uninstall Confluence                  #
########################################
sub uninstallConfluence {
	my $application = "Confluence";
	my $subname     = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");
	uninstallGeneric($application);
}

########################################
#UpgradeConfluence                     #
########################################
sub upgradeConfluence {
	my $serverXMLFile;
	my $initPropertiesFile;
	my @parameterNull;
	my $javaOptsValue;
	my $catalinaOptsValue;
	my $application   = "Confluence";
	my $lcApplication = lc($application);
	my $javaMemParameterFile;
	my $osUser;
	my $jdbcJAR;
	my $needJDBC;
	my $input;
	my $javaParameterName;
	my $downloadArchivesUrl =
	  "http://www.atlassian.com/software/confluence/download-archives";
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	#Set up list of config items that are requred for this install to run
	my @requiredConfigItems;
	@requiredConfigItems = (
		"confluence.appContext",
		"confluence.enable",
		"confluence.dataDir",
		"confluence.installDir",
		"confluence.runAsService",
		"confluence.serverPort",
		"confluence.connectorPort",
		"confluence.javaMinMemory",
		"confluence.javaMaxMemory",
		"confluence.javaMaxPermSize",
		"confluence.processSearchParameter1",
		"confluence.processSearchParameter2",
		"confluence.crowdIntegration",
		"confluence.osUser"
	);

	if ( $globalConfig->param("general.apacheProxy") eq "TRUE" ) {
		if (
			$globalConfig->param("general.apacheProxySingleDomain") eq "FALSE" )
		{
			push( @requiredConfigItems, "confluence.apacheProxyPort" );
			push( @requiredConfigItems, "confluence.apacheProxySSL" );
			push( @requiredConfigItems, "confluence.apacheProxyHost" );
		}
	}

	#Back up the Crowd configuration files
	if ( $globalConfig->param("$lcApplication.crowdIntegration") eq "TRUE" ) {
		$log->info("$subname: Backing up Crowd configuration files.");
		print "Backing up the Crowd configuration files...\n\n";
		if ( -e $globalConfig->param("$lcApplication.installDir")
			. "/confluence/WEB-INF/classes/crowd.properties" )
		{
			copyFile(
				$globalConfig->param("$lcApplication.installDir")
				  . "/confluence/WEB-INF/classes/crowd.properties",
				"$Bin/working/crowd.properties.$lcApplication"
			);
		}
		else {
			print
"No crowd.properties currently exists for $application, will not copy.\n\n";
			$log->info(
"$subname: No crowd.properties currently exists for $application, will not copy."
			);
		}
	}

	#Force update config items for search parameters
	$globalConfig->param( "$lcApplication.processSearchParameter1", "java" );
	$globalConfig->param( "$lcApplication.processSearchParameter2",
		"classpath " . $globalConfig->param("$lcApplication.installDir") );
	$globalConfig->write($configFile);
	loadSuiteConfig();

	#Run generic upgrader steps
	upgradeGeneric( $application, $downloadArchivesUrl, \@requiredConfigItems );
	$osUser = $globalConfig->param("$lcApplication.osUser")
	  ; #we get this after install in CASE the installer changes the configured user in future

	#Perform application specific configuration
	print "Applying configuration settings to the install, please wait...\n\n";

	$serverXMLFile =
	  escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
	  . "/conf/server.xml";

	$initPropertiesFile =
	  escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
	  . "/confluence/WEB-INF/classes/$lcApplication-init.properties";
	$javaMemParameterFile =
	  escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
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

	#Update the server config with reverse proxy configuration
	$log->info( "$subname: Updating the reverse proxy configuration in "
		  . $serverXMLFile );
	print "Applying Apache proxy parameters to config...\n\n";
	if ( $globalConfig->param("general.apacheProxy") eq "TRUE" ) {
		if ( $globalConfig->param("general.apacheProxySingleDomain") eq "TRUE" )
		{
			updateXMLAttribute( $serverXMLFile, "///Connector", "proxyName",
				$globalConfig->param("general.apacheProxyHost") );

			if ( $globalConfig->param("general.apacheProxySSL") eq "TRUE" ) {
				updateXMLAttribute( $serverXMLFile, "///Connector", "scheme",
					"https" );
			}
			else {
				updateXMLAttribute( $serverXMLFile, "///Connector", "scheme",
					"http" );
			}
			updateXMLAttribute( $serverXMLFile, "///Connector", "secure",
				"false" );
			updateXMLAttribute( $serverXMLFile, "///Connector", "proxyPort",
				$globalConfig->param("general.apacheProxyPort") );
		}
		else {
			updateXMLAttribute( $serverXMLFile, "///Connector", "proxyName",
				$globalConfig->param("$lcApplication.apacheProxyHost") );
			if ( $globalConfig->param("$lcApplication.apacheProxySSL") eq
				"TRUE" )
			{
				updateXMLAttribute( $serverXMLFile, "///Connector", "scheme",
					"https" );
			}
			else {
				updateXMLAttribute( $serverXMLFile, "///Connector", "scheme",
					"http" );
			}
			updateXMLAttribute( $serverXMLFile, "///Connector", "secure",
				"false" );
			updateXMLAttribute( $serverXMLFile, "///Connector", "proxyPort",
				$globalConfig->param("$lcApplication.apacheProxyPort") );
		}
	}

	#Edit Confluence config file to reference homedir
	$log->info( "$subname: Applying homedir in " . $initPropertiesFile );
	print "Applying home directory to config...\n\n";
	updateLineInFile(
		$initPropertiesFile,
		"confluence.home=",
		"confluence.home="
		  . escapeFilePath( $globalConfig->param("$lcApplication.dataDir") ),
		"# confluence.home="
	);

	@parameterNull = $globalConfig->param("$lcApplication.javaParams");
	if (   ( $#parameterNull == -1 )
		|| $globalConfig->param("$lcApplication.javaParams") eq ""
		|| $globalConfig->param("$lcApplication.javaParams") eq "default" )
	{
		$javaOptsValue = "NOJAVAOPTSCONFIGSPECIFIED";
	}
	else {
		$javaOptsValue = "CONFIGSPECIFIED";
	}

#Check if we are installing version below 5.6 to maintain backwards compatibility
	if (
		compareTwoVersions(
			$globalConfig->param("$lcApplication.installedVersion"), "5.5.6" )
		ne "GREATER"
	  )
	{
		$javaParameterName = "JAVA_OPTS";
	}
	else {

	   #newer than 5.5.6 - As of 5.6 Confluence uses CATALINA_OPTS not JAVA_OPTS
		$javaParameterName = "CATALINA_OPTS";
	}

	#Apply the JavaOpts configuration (if any)
	print "Applying Java_Opts configuration to install...\n\n";
	if ( $javaOptsValue ne "NOJAVAOPTSCONFIGSPECIFIED" ) {
		updateJavaOpts(
			escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
			  . "/bin/setenv.sh",
			$javaParameterName,
			getConfigItem( "$lcApplication.javaParams", $globalConfig )
		);
	}

	#Apply Catalina Opts to Install
	@parameterNull = $globalConfig->param("$lcApplication.catalinaOpts");
	if (   ( $#parameterNull == -1 )
		|| $globalConfig->param("$lcApplication.catalinaOpts") eq ""
		|| $globalConfig->param("$lcApplication.catalinaOpts") eq "default" )
	{
		$catalinaOptsValue = "NOCATALINAOPTSCONFIGSPECIFIED";
	}
	else {
		$catalinaOptsValue = "CONFIGSPECIFIED";
	}

	print "Applying CATALINA_OPTS configuration to install...\n\n";
	if ( $javaOptsValue ne "NOCATALINAOPTSCONFIGSPECIFIED" ) {
		updateCatalinaOpts(
			$application,
			escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
			  . "/bin/setenv.sh",
			"CATALINA_OPTS=",
			getConfigItem( "$lcApplication.catalinaOpts", $globalConfig )
		);
	}

	#Restore the Crowd configuration files
	if ( $globalConfig->param("$lcApplication.crowdIntegration") eq "TRUE" ) {
		$log->info("$subname: Restoring Crowd configuration files.");
		print "Restoring the Crowd configuration files...\n\n";
		if (
			-e escapeFilePath(
				$globalConfig->param("$lcApplication.installDir")
				  . "/confluence/WEB-INF/classes/crowd.properties"
			)
		  )
		{
			backupFile(
				escapeFilePath(
					$globalConfig->param("$lcApplication.installDir")
					  . "/confluence/WEB-INF/classes/crowd.properties"
				),
				$osUser
			);
		}
		if ( -e escapeFilePath("$Bin/working/crowd.properties.$lcApplication") )
		{
			copyFile(
				escapeFilePath("$Bin/working/crowd.properties.$lcApplication"),
				escapeFilePath(
					$globalConfig->param("$lcApplication.installDir")
					  . "/confluence/WEB-INF/classes/crowd.properties"
				)
			);

			chownFile(
				$osUser,
				escapeFilePath(
					$globalConfig->param("$lcApplication.installDir")
					  . "/confluence/WEB-INF/classes/crowd.properties"
				)
			);
		}
		else {
			print
"No crowd.properties currently exists for $application that has been backed up, will not restore.\n\n";
			$log->info(
"$subname: No crowd.properties currently exists for $application that has been backed up, will not restore."
			);
		}
	}

	print "Configuration settings have been applied successfully.\n\n";

	#Run any additional steps

#Check if we are installing version below 5.6 to maintain backwards compatibility
	if (
		compareTwoVersions(
			$globalConfig->param("$lcApplication.installedVersion"), "5.5.6" )
		ne "GREATER"
	  )
	{
		$javaParameterName = "JAVA_OPTS";
	}
	else {

	   #newer than 5.5.6 - As of 5.6 Confluence uses CATALINA_OPTS not JAVA_OPTS
		$javaParameterName = "CATALINA_OPTS";
	}

	#Update Java Memory Parameters
	print "Applying Java memory configuration to install...\n\n";
	$log->info( "$subname: Applying Java memory parameters to "
		  . $javaMemParameterFile );
	updateJavaMemParameter( $javaMemParameterFile, $javaParameterName, "-Xms",
		$globalConfig->param("$lcApplication.javaMinMemory") );
	updateJavaMemParameter( $javaMemParameterFile, $javaParameterName, "-Xmx",
		$globalConfig->param("$lcApplication.javaMaxMemory") );
	updateJavaMemParameter( $javaMemParameterFile, $javaParameterName,
		"-XX:MaxPermSize=",
		$globalConfig->param("$lcApplication.javaMaxPermSize") );

#If Oracle is the Database, Confluence does not come with the driver so check for it and copy if we need it

	@parameterNull = $globalConfig->param("general.dbJDBCJar");
	if ( ( $#parameterNull == -1 ) ) {
		$jdbcJAR = "";
		$log->info("$subname: JDBC undefined in settings.cnf");
	}
	else {
		$jdbcJAR = $globalConfig->param("general.dbJDBCJar");
		$log->info("$subname: JDBC is defined in settings.cnf as $jdbcJAR");
	}

	if ( $globalConfig->param("general.targetDBType") eq "Oracle" ) {
		if ( $lcApplication eq "confluence" ) {
			print
"Database is configured as Oracle, copying the JDBC connector to $application install if needed.\n\n";
			if (
				-e escapeFilePath(
					$globalConfig->param("$lcApplication.installDir")
				)
				. "/lib/ojdbc6.jar"
				|| -e escapeFilePath(
					$globalConfig->param("$lcApplication.installDir")
				)
				. "/confluence/WEB-INF/lib/ojdbc6.jar"
			  )
			{
				$needJDBC = "FALSE";
				$log->info(
"$subname: JDBC already exists in $application lib directories"
				);
			}
			else {
				$needJDBC = "TRUE";
				$log->info(
"$subname: JDBC does not exist in $application lib directories"
				);
			}
		}

		if ( $needJDBC eq "TRUE" && $jdbcJAR ne "" ) {
			$log->info(
				"$subname: Copying Oracle JDBC to $application lib directory");
			copyFile(
				$globalConfig->param("general.dbJDBCJar"),
				escapeFilePath(
					$globalConfig->param("$lcApplication.installDir")
				  )
				  . "/lib/"
			);

			#Chown the files again
			$log->info(
				"$subname: Chowning "
				  . escapeFilePath(
					$globalConfig->param("$lcApplication.installDir")
				  )
				  . "/lib/"
				  . " to $osUser following Oracle JDBC install."
			);
			chownRecursive(
				$osUser,
				escapeFilePath(
					$globalConfig->param("$lcApplication.installDir")
				  )
				  . "/lib/"
			);

		}
		elsif ( $needJDBC eq "FALSE" ) {
			$log->info(
"$subname: $application already has ojdbc6.jar, no need to copy. "
			);
		}
		elsif ( $needJDBC eq "TRUE" && $jdbcJAR eq "" ) {
			$log->info(
"$subname: JDBC needed for Oracle but none defined in settings.cnf. Warning user."
			);
			print
"It appears we need the ojdb6.jar file but you have not set a path to it in settings.cnf. Therefore you will need to manually copy the ojdbc6.jar file to the $application lib directory manually before it will work. Please press enter to continue...";
			$input = <STDIN>;
		}
	}

	#Apply Seraph Config
	if ( $globalConfig->param("$lcApplication.crowdSSO") eq "TRUE" ) {
		backupFile(
			escapeFilePath(
				$globalConfig->param("$lcApplication.installDir")
				  . "/confluence/WEB-INF/classes/seraph-config.xml"
			),
			$osUser
		);
		updateSeraphConfig(
			$application,
			escapeFilePath(
				$globalConfig->param("$lcApplication.installDir")
				  . "/confluence/WEB-INF/classes/seraph-config.xml"
			),
			"com.atlassian.confluence.user.ConfluenceCrowdSSOAuthenticator",
			"com.atlassian.confluence.user.ConfluenceAuthenticator"
		);
	}

	#Generate the init.d file
	print
"Setting up initd files and run as a service (if configured) please wait...\n\n";
	$log->info("$subname: Generating init.d file for $application.");

	generateInitD(
		$application,
		$osUser,
		escapeFilePath( $globalConfig->param("$lcApplication.installDir") ),
		"/bin/start-confluence.sh",
		"/bin/stop-confluence.sh",
		$globalConfig->param("$lcApplication.processSearchParameter1"),
		$globalConfig->param("$lcApplication.processSearchParameter2")
	);

	#Clear confluence plugin cache as per [#ATLASMGR-374]
	clearConfluencePluginCache();

	#Finally run generic post install tasks
	postUpgradeGeneric($application);
}

#######################################################################
#END CONFLUENCE MANAGER FUNCTIONS                                     #
#######################################################################

#######################################################################
#BEGIN CROWD MANAGER FUNCTIONS                                        #
#######################################################################

########################################
#getExistingCrowdConfig                #
########################################
sub getExistingCrowdConfig {
	my $cfg;
	my $defaultValue;
	my $application   = "Crowd";
	my $mode          = "CREATE";
	my $lcApplication = lc($application);
	my $subname       = ( caller(0) )[3];
	my $serverConfigFile;
	my $serverSetEnvFile;
	my $input;
	my $LOOP = 0;
	my $returnValue;

	$log->debug("BEGIN: $subname");

	$cfg = $_[0];

	while ( $LOOP == 0 ) {

		#Ask for install dir
		genConfigItem(
			$mode,
			$cfg,
			"$lcApplication.installDir",
"Please enter the directory $application is currently installed into.",
			"",
			'(?!^.*/$)^(/.*)',
"The input you entered was not in the valid format of '/folder'. Please ensure you enter the absolute path with a "
			  . "leading '/' and NO trailing '/'.\n\n"
		);

		if ( -d escapeFilePath( $cfg->param("$lcApplication.installDir") ) ) {
			$LOOP = 1;    #break loop as directory exists
			$log->info( "$subname: Directory "
				  . escapeFilePath( $cfg->param("$lcApplication.installDir") )
				  . " exists. Proceeding..." );
			print "The directory "
			  . escapeFilePath( $cfg->param("$lcApplication.installDir") )
			  . " exists. Proceeding...\n\n";
		}
		else {
			print "The directory "
			  . escapeFilePath( $cfg->param("$lcApplication.installDir") )
			  . " does not exist. Please try again.\n\n";
			$log->info( "The directory "
				  . escapeFilePath( $cfg->param("$lcApplication.installDir") )
				  . " does not exist. Please try again." );
		}
	}

	#Ask for current installed version
	genConfigItem(
		$mode,
		$cfg,
		"$lcApplication.installedVersion",
		"Please enter the version of $application that is currently installed.",
		"",
		'^[0-9]+\.([0-9]+|[0-9]+\.[0-9]+)$',
"The input you entered was not in the valid format of 'x.x.x or x.x' (where x is a version number). Please ensure you enter the version number correctly "
		  . "\n\n"
	);

	genConfigItem(
		$mode,
		$cfg,
		"$lcApplication.javaParams",
"Enter any additional parameters currently added to the JAVA RUN_OPTS for your $application install. Just press enter if you have none.",
		"",
		"",
		""
	);

	genConfigItem(
		$mode,
		$cfg,
		"$lcApplication.catalinaOpts",
"Enter any additional currently added to the Java CATALINA_OPTS for your $application install. Just press enter if you have none.",
		"",
		"",
		""
	);

	genConfigItem(
		$mode,
		$cfg,
		"crowd.appContext",
"Enter the context that Crowd currently runs under (i.e. /crowd or /login). Write NULL to blank out the context.",
		"/crowd",
		'(?!^.*/$)^(/.*)',
"The input you entered was not in the valid format of '/folder'. Please ensure you enter the path with a "
		  . "leading '/' and NO trailing '/'.\n\n"
	);

	if (   $cfg->param("general.apacheProxy") eq "TRUE"
		&& $cfg->param("general.apacheProxySingleDomain") eq "FALSE" )
	{
		genConfigItem(
			$mode,
			$cfg,
			"crowd.apacheProxyHost",
"Please enter the base URL Crowd currently runs on (i.e. the proxyName such as yourdomain.com).",
			"",
			$hostnameRegex,
"The input you entered was not in the valid format of 'yourdomain.com' or 'subdomain.yourdomain.com'. Please try again.\n\n"
		);

		genBooleanConfigItem( $mode, $cfg, "crowd.apacheProxySSL",
			"Do you currently run Crowd over SSL.", "no" );

		genConfigItem(
			$mode,
			$cfg,
			"crowd.apacheProxyPort",
"Please enter the port number that Apache currently serves Crowd on (80 for HTTP, 443 for HTTPS in standard situations).",
			"80",
			'^([0-9]*)$',
"The input you entered was not a valid port number, please try again.\n\n"
		);
	}

	$serverSetEnvFile =
	  escapeFilePath( $cfg->param("$lcApplication.installDir") )
	  . "/apache-tomcat/bin/setenv.sh";

	$serverConfigFile =
	  escapeFilePath( $cfg->param("$lcApplication.installDir") )
	  . "/apache-tomcat/conf/server.xml";

	genBooleanConfigItem(
		$mode,
		$cfg,
		"$lcApplication.runAsService",
"Does your $application instance run as a service (i.e. runs on boot)? yes/no.",
		"yes"
	);

	print
"Please wait, attempting to get the $application data/home directory from it's config files...\n\n";
	$log->info(
"$subname: Attempting to get $application data directory from config file $serverConfigFile."
	);

	#get data/home directory
	$returnValue = getLineFromFile(
		escapeFilePath( $cfg->param("$lcApplication.installDir") )
		  . "/crowd-webapp/WEB-INF/classes/crowd-init.properties",
		"crowd.home\\s?=", ".*=\\s?(.*)"
	);

	if ( $returnValue eq "NOTFOUND" ) {
		$log->info(
"$subname: Unable to locate $application data directory. Asking user for input."
		);
		genConfigItem(
			$mode,
			$cfg,
			"$lcApplication.dataDir",
"Unable to find the data directory in the expected location in the $application config. Please enter the directory $application"
			  . "'s data is *currently* stored in.",
			"",
			'(?!^.*/$)^(/.*)',
"The input you entered was not in the valid format of '/folder'. Please ensure you enter the absolute path with a "
			  . "leading '/' and NO trailing '/'.\n\n"
		);
	}
	else {
		$cfg->param( "$lcApplication.dataDir", $returnValue );
		print
"$application data directory has been found successfully and added to the config file...\n\n";
		$log->info(
			"$subname: $application data directory found and added to config."
		);
	}

	$returnValue = "";

	print
"Please wait, attempting to get the $application connectorPort from it's config files...\n\n";
	$log->info(
"$subname: Attempting to get $application connectorPort from config file $serverConfigFile."
	);

	#Get connector port from file
	$returnValue = getXMLAttribute( $serverConfigFile, "///Connector", "port" );
	if ( $returnValue eq "NOTFOUND" ) {
		$log->info(
"$subname: Unable to locate $application connectorPort. Asking user for input."
		);
		genConfigItem(
			$mode,
			$cfg,
			"$lcApplication.connectorPort",
"Unable to find the connector port in the expected location in the $application config. Please enter the Connector port $application *currently* runs on (note this is the port you will access in the browser).",
			"8095",
			'^([0-9]*)$',
"The port number you entered contained invalid characters. Please ensure you enter only digits.\n\n"
		);
	}
	else {
		$cfg->param( "$lcApplication.connectorPort", $returnValue );
		print
"$application connectorPort has been found successfully and added to the config file...\n\n";
		$log->info(
			"$subname: $application connectorPort found and added to config.");
	}

	$returnValue = "";

	print
"Please wait, attempting to get the $application serverPort from it's config files...\n\n";
	$log->info(
"$subname: Attempting to get $application serverPort from config file $serverConfigFile."
	);

	#Get connector port from file
	$returnValue = getXMLAttribute( $serverConfigFile, "/Server", "port" );

	if ( $returnValue eq "NOTFOUND" ) {
		$log->info(
"$subname: Unable to locate $application serverPort. Asking user for input."
		);
		genConfigItem(
			$mode,
			$cfg,
			"$lcApplication.serverPort",
"Unable to find the server port in the expected location in the $application config. Please enter the Server port $application *currently* runs on (note this is the tomcat control port).",
			"8001",
			'^([0-9]*)$',
"The port number you entered contained invalid characters. Please ensure you enter only digits.\n\n"
		);
	}
	else {
		$cfg->param( "$lcApplication.serverPort", $returnValue );
		print
"$application serverPort has been found successfully and added to the config file...\n\n";
		$log->info(
			"$subname: $application serverPort found and added to config.");
	}

	$returnValue = "";

	print
"Please wait, attempting to get the $application Xms java memory parameter from it's config files...\n\n";
	$log->info(
"$subname: Attempting to get $application Xms java memory parameter from config file $serverConfigFile."
	);
	$returnValue =
	  getJavaMemParameter( $serverSetEnvFile, "JAVA_OPTS", "-Xms" );
	if ( $returnValue eq "NOTFOUND" ) {
		$log->info(
"$subname: Unable to locate $application Xms memory parameter. Asking user for input."
		);
		genConfigItem(
			$mode,
			$cfg,
			"$lcApplication.javaMinMemory",
"Unable to find the java Xms memory parameter in the expected location in the $application config. Please enter the minimum amount of memory *currently* assigned to $application.",
			"256m",
			'^([0-9]*m)$',
"The memory value you entered is in an invalid format. Please ensure you use the format '1234m'. (i.e. '256m')"
		);
	}
	else {
		$cfg->param( "$lcApplication.javaMinMemory", $returnValue );
		print
"$application Xms java memory parameter has been found successfully and added to the config file...\n\n";
		$log->info(
"$subname: $application Xms java memory parameter found and added to config."
		);
	}

	$returnValue = "";

	print
"Please wait, attempting to get the $application Xmx java memory parameter from it's config files...\n\n";
	$log->info(
"$subname: Attempting to get $application Xmx java memory parameter from config file $serverConfigFile."
	);
	$returnValue =
	  getJavaMemParameter( $serverSetEnvFile, "JAVA_OPTS", "-Xmx" );
	if ( $returnValue eq "NOTFOUND" ) {
		$log->info(
"$subname: Unable to locate $application Xmx memory parameter. Asking user for input."
		);
		genConfigItem(
			$mode,
			$cfg,
			"$lcApplication.javaMaxMemory",
"Unable to find the java Xmx memory parameter in the expected location in the $application config. Please enter the maximum amount of memory *currently* assigned to $application.",
			"512m",
			'^([0-9]*m)$',
"The memory value you entered is in an invalid format. Please ensure you use the format '1234m'. (i.e. '256m')"
		);
	}
	else {
		$cfg->param( "$lcApplication.javaMaxMemory", $returnValue );
		print
"$application Xmx java memory parameter has been found successfully and added to the config file...\n\n";
		$log->info(
"$subname: $application Xmx java memory parameter found and added to config."
		);
	}

	$returnValue = "";

	print
"Please wait, attempting to get the $application XX:MaxPermSize java memory parameter from it's config files...\n\n";
	$log->info(
"$subname: Attempting to get $application XX:MaxPermSize java memory parameter from config file $serverConfigFile."
	);
	$returnValue =
	  getJavaMemParameter( $serverSetEnvFile, "JAVA_OPTS", "-XX:MaxPermSize=" );
	if ( $returnValue eq "NOTFOUND" ) {
		$log->info(
"$subname: Unable to locate $application XX:MaxPermSize memory parameter. Asking user for input."
		);
		genConfigItem(
			$mode,
			$cfg,
			"$lcApplication.javaMaxPermSize",
"Unable to find the java XX:MaxPermSize memory parameter in the expected location in the $application config. Please enter the maximum amount of permGen memory *currently* assigned to $application.",
			"256m",
			'^([0-9]*m)$',
"The memory value you entered is in an invalid format. Please ensure you use the format '1234m'. (i.e. '256m')"
		);
	}
	else {
		$cfg->param( "$lcApplication.javaMaxPermSize", $returnValue );
		print
"$application XX:MaxPermSize java memory parameter has been found successfully and added to the config file...\n\n";
		$log->info(
"$subname: $application XX:MaxPermSize java memory parameter found and added to config."
		);
	}

	$returnValue = "";

	#getOSuser
	open( my $inputFileHandle,
		'<', escapeFilePath( $cfg->param("$lcApplication.installDir") ) )
	  or $log->logdie(
"Unable to open install dir for $application to test who owns it. Really this should never happen as we have already tested that the directory exists."
	  );
	my (
		$dev,   $ino,     $fileMode, $nlink, $uid,
		$gid,   $rdev,    $size,     $atime, $mtime,
		$ctime, $blksize, $blocks
	) = stat($inputFileHandle);
	$returnValue = getpwuid($uid);

	close $inputFileHandle;

	#confirmWithUserThatIsTheCorrectOSUser
	$input = getBooleanInput(
"We have detected that the user $application runs under is '$returnValue'. Is this correct? yes/no [yes]: "
	);
	print "\n";
	if ( $input eq "default" || $input eq "yes" ) {
		$cfg->param( "$lcApplication.osUser", $returnValue );
		print
		  "The osUser $returnValue has been added to the config file...\n\n";
		$log->info(
"$subname: User confirmed that the user $application runs under is $returnValue. This has been added to the config."
		);
	}
	else {
		genConfigItem(
			$mode,
			$cfg,
			"$lcApplication.osUser",
"In that case please enter the user that $application *currently* runs under.",
			"",
			'^([a-zA-Z0-9]*)$',
"The user you entered was in an invalid format. Please ensure you enter only letters and numbers without any spaces or other characters.\n\n"
		);
	}

	if (   $cfg->param("general.apacheProxy") eq "TRUE"
		&& $cfg->param("general.apacheProxySingleDomain") eq "FALSE" )
	{
		$returnValue = "";

		print
"Please wait, attempting to get the Apache proxy base hostname configuration for $application from the configuration files...\n\n";
		$log->info(
"$subname: Attempting to get $application proxyName from config file $serverConfigFile."
		);
		$returnValue =
		  getXMLAttribute( $serverConfigFile, "///Connector", "proxyName" );

		if ( $returnValue eq "NOTFOUND" ) {
			$log->info(
"$subname: Unable to locate $application proxyName. Asking user for input."
			);
			genConfigItem(
				$mode,
				$cfg,
				"$lcApplication.apacheProxyHost",
"Unable to find the base hostname attribute in the expected location in the $application config. Please enter the base URL that will be serving the site (i.e. the proxyName such as yourdomain.com).",
				"",
				$hostnameRegex,
"The input you entered was not in the valid format of 'yourdomain.com' or 'subdomain.yourdomain.com'. Please try again.\n\n"
			);
		}
		else {
			$cfg->param( "$lcApplication.apacheProxyHost", $returnValue );
			print
"$application base hostname has been found successfully and added to the config file...\n\n";
			$log->info(
"$subname: $application base hostname found and added to config."
			);
		}

		$returnValue = "";

		print
"Please wait, attempting to get the Apache proxy scheme configuration for $application from the configuration files...\n\n";
		$log->info(
"$subname: Attempting to get $application proxy scheme from config file $serverConfigFile."
		);
		$returnValue =
		  getXMLAttribute( $serverConfigFile, "///Connector", "scheme" );

		if ( $returnValue eq "NOTFOUND" ) {
			$log->info(
"$subname: Unable to locate $application proxy scheme. Asking user for input."
			);
			genBooleanConfigItem(
				$mode,
				$cfg,
				"$lcApplication.apacheProxySSL",
"Unable to locate the Apache proxy scheme configuration in $application config. Will you be running $application over SSL.",
				"no"
			);
		}
		else {
			if ( $returnValue eq "http" ) {
				$log->info(
"$subname: return value for Apache Proxy Scheme config is 'http'."
				);
				$cfg->param( "$lcApplication.apacheProxySSL", "FALSE" );
			}
			elsif ( $returnValue eq "https" ) {
				$log->info(
"$subname: return value for Apache Proxy Scheme config is 'http'."
				);
				$cfg->param( "$lcApplication.apacheProxySSL", "TRUE" );
			}
			else {
				$log->info(
"$subname: return value for Apache Proxy Scheme config is 'UNKNOWN' This is not good."
				);
				$cfg->param( "$lcApplication.apacheProxySSL", "UNKNOWN" );
			}
			print
"$application Apache Proxy scheme has been found successfully and added to the config file...\n\n";
			$log->info(
				"$subname: $application proxy scheme found and added to config."
			);
		}

		$returnValue = "";

		print
"Please wait, attempting to get the Apache proxy port configuration for $application from the configuration files...\n\n";
		$log->info(
"$subname: Attempting to get $application proxyPort from config file $serverConfigFile."
		);
		$returnValue =
		  getXMLAttribute( $serverConfigFile, "///Connector", "proxyPort" );

		if ( $returnValue eq "NOTFOUND" ) {
			$log->info(
"$subname: Unable to locate $application proxyPort. Asking user for input."
			);
			genConfigItem(
				$mode,
				$cfg,
				"$lcApplication.apacheProxyPort",
"Unable to find the Apache proxy port attribute in the expected location in the $application config. Please enter the port number that Apache currently serves on (80 for HTTP, 443 for HTTPS in standard situations).",
				"80/443",
				'^([0-9]*)$',
"The input you entered was not a valid port number, please try again.\n\n"
			);
		}
		else {
			$cfg->param( "$lcApplication.apacheProxyPort", $returnValue );
			print
"$application base hostname has been found successfully and added to the config file...\n\n";
			$log->info(
"$subname: $application base hostname found and added to config."
			);
		}
	}

	#Set up some defaults for Crowd
	$cfg->param( "$lcApplication.tomcatDir", "/apache-tomcat" );
	$cfg->param( "$lcApplication.webappDir", "/crowd-webapp" );
	$cfg->param( "$lcApplication.enable",    "TRUE" );

	$cfg->write($configFile);
	loadSuiteConfig();

	print
"We now have the $application config and it has been written to the config file. Please press enter to continue.\n";
	$input = <STDIN>;
}

########################################
#GenerateCrowdConfig                   #
########################################
sub generateCrowdConfig {
	my $cfg;
	my $mode;
	my $defaultValue;
	my $application = "Crowd";
	my $subname     = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	$mode = $_[0];
	$cfg  = $_[1];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_mode", $mode );

	genConfigItem(
		$mode,
		$cfg,
		"crowd.installDir",
		"Please enter the directory Crowd will be installed into.",
		$cfg->param("general.rootInstallDir") . "/crowd",
		'(?!^.*/$)^(/.*)',
"The input you entered was not in the valid format of '/folder'. Please ensure you enter the absolute path with a "
		  . "leading '/' and NO trailing '/'.\n\n"
	);

	genConfigItem(
		$mode,
		$cfg,
		"crowd.dataDir",
		"Please enter the directory Crowd's data will be stored in.",
		$cfg->param("general.rootDataDir") . "/crowd",
		'(?!^.*/$)^(/.*)',
"The input you entered was not in the valid format of '/folder'. Please ensure you enter the absolute path with a "
		  . "leading '/' and NO trailing '/'.\n\n"
	);

	genConfigItem(
		$mode,
		$cfg,
		"crowd.osUser",
		"Enter the user that Crowd will run under.",
		"crowd",
		'^([a-zA-Z0-9]*)$',
"The user you entered was in an invalid format. Please ensure you enter only letters and numbers without any spaces or other characters.\n\n"
	);

	genConfigItem(
		$mode,
		$cfg,
		"crowd.appContext",
"Enter the context that Crowd should run under (i.e. /crowd or /login). Write NULL to blank out the context.",
		"/crowd",
		'(?!^.*/$)^(/.*)',
"The input you entered was not in the valid format of '/folder'. Please ensure you enter the path with a "
		  . "leading '/' and NO trailing '/'.\n\n"
	);

	genConfigItem(
		$mode,
		$cfg,
		"crowd.connectorPort",
"Please enter the Connector port Crowd will run on (note this is the port you will access in the browser).",
		"8095",
		'^([0-9]*)$',
"The port number you entered contained invalid characters. Please ensure you enter only digits.\n\n"
	);
	checkConfiguredPort( $application, "crowd.connectorPort", $cfg );

	genConfigItem(
		$mode,
		$cfg,
		"crowd.serverPort",
"Please enter the SERVER port Crowd will run on (note this is the control port not the port you access in a browser).",
		"8001",
		'^([0-9]*)$',
"The port number you entered contained invalid characters. Please ensure you enter only digits.\n\n"
	);
	checkConfiguredPort( $application, "crowd.serverPort", $cfg );

	genConfigItem(
		$mode,
		$cfg,
		"crowd.javaParams",
"Enter any additional parameters you would like to add to the Java RUN_OPTS.",
		"",
		"",
		""
	);

	genConfigItem(
		$mode,
		$cfg,
		"crowd.catalinaOpts",
"Enter any additional parameters you would like to add to the Java CATALINA_OPTS.",
		"",
		"",
		""
	);

	genConfigItem(
		$mode,
		$cfg,
		"crowd.javaMinMemory",
		"Enter the minimum amount of memory you would like to assign to Crowd.",
		"128m",
		'^([0-9]*m)$',
"The memory value you entered is in an invalid format. Please ensure you use the format '1234m'. (i.e. '256m')"
	);

	genConfigItem(
		$mode,
		$cfg,
		"crowd.javaMaxMemory",
		"Enter the maximum amount of memory you would like to assign to Crowd.",
		"512m",
		'^([0-9]*m)$',
"The memory value you entered is in an invalid format. Please ensure you use the format '1234m'. (i.e. '256m')"
	);

	genConfigItem(
		$mode,
		$cfg,
		"crowd.javaMaxPermSize",
"Enter the amount of memory for the MAX_PERM_SIZE parameter that you would like to assign to Crowd.",
		"256m",
		'^([0-9]*m)$',
"The memory value you entered is in an invalid format. Please ensure you use the format '1234m'. (i.e. '256m')"
	);

	if (   $cfg->param("general.apacheProxy") eq "TRUE"
		&& $cfg->param("general.apacheProxySingleDomain") eq "FALSE" )
	{
		genConfigItem(
			$mode,
			$cfg,
			"crowd.apacheProxyHost",
"Please enter the base URL that will be serving the site (i.e. the proxyName such as yourdomain.com).",
			"",
			$hostnameRegex,
"The input you entered was not in the valid format of 'yourdomain.com' or 'subdomain.yourdomain.com'. Please try again.\n\n"
		);

		genBooleanConfigItem( $mode, $cfg, "crowd.apacheProxySSL",
			"Will you be running Crowd over SSL.", "no" );

		genConfigItem(
			$mode,
			$cfg,
			"crowd.apacheProxyPort",
"Please enter the port number that Apache will serve on (80 for HTTP, 443 for HTTPS in standard situations).",
			"80",
			'^([0-9]*)$',
"The input you entered was not a valid port number, please try again.\n\n"
		);
	}

	genBooleanConfigItem( $mode, $cfg, "crowd.runAsService",
		"Would you like to run Crowd as a service? yes/no.", "yes" );

	#Set up some defaults for Crowd
	$cfg->param( "crowd.tomcatDir",               "/apache-tomcat" );
	$cfg->param( "crowd.webappDir",               "/crowd-webapp" );
	$cfg->param( "crowd.processSearchParameter1", "java" );
	$cfg->param( "crowd.processSearchParameter2",
		    $cfg->param("crowd.installDir")
		  . $cfg->param("crowd.tomcatDir")
		  . "/bin/bootstrap.jar" );

	$cfg->param( "crowd.enable", "TRUE" );
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
	my @parameterNull;
	my $javaOptsValue;
	my $catalinaOptsValue;
	my @requiredConfigItems;
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	#Set up list of config items that are requred for this install to run
	$lcApplication       = lc($application);
	@requiredConfigItems = (
		"crowd.appContext",      "crowd.enable",
		"crowd.dataDir",         "crowd.installDir",
		"crowd.runAsService",    "crowd.serverPort",
		"crowd.connectorPort",   "crowd.osUser",
		"crowd.tomcatDir",       "crowd.webappDir",
		"crowd.javaMinMemory",   "crowd.javaMaxMemory",
		"crowd.javaMaxPermSize", "crowd.processSearchParameter1",
		"crowd.processSearchParameter2"
	);

	if ( $globalConfig->param("general.apacheProxy") eq "TRUE" ) {
		if (
			$globalConfig->param("general.apacheProxySingleDomain") eq "FALSE" )
		{
			push( @requiredConfigItems, "crowd.apacheProxyPort" );
			push( @requiredConfigItems, "crowd.apacheProxySSL" );
			push( @requiredConfigItems, "crowd.apacheProxyHost" );
		}
	}

	#bugFix for versions prior to v0.1.6 see [#ATLASMGR-265]
	if ( $globalConfig->param("crowd.processSearchParameter2") eq
		"Dcatalina.base=/drive2/opt/crowd/apache-tomcat" )
	{

		#force the value to NULL so that config will need to be regenerated.
		$globalConfig->param( "crowd.processSearchParameter2", "" );

		#Write config and reload
		$log->info("Writing out config file to disk.");
		$globalConfig->write($configFile);
		loadSuiteConfig();
	}

	#Force update config items for search parameters
	$globalConfig->param( "$lcApplication.processSearchParameter1", "java" );
	$globalConfig->param( "$lcApplication.processSearchParameter2",
		    "Dcatalina.base="
		  . $globalConfig->param("$lcApplication.installDir")
		  . $globalConfig->param("$lcApplication.tomcatDir") );
	$globalConfig->write($configFile);
	loadSuiteConfig();

	#Run generic installer steps
	installGeneric( $application, $downloadArchivesUrl, \@requiredConfigItems );
	$osUser = $globalConfig->param("$lcApplication.osUser")
	  ; #we get this after install in CASE the installer changes the configured user in future

	#Perform application specific configuration
	print "Applying configuration settings to the install, please wait...\n\n";

	$serverXMLFile =
	    escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
	  . $globalConfig->param("$lcApplication.tomcatDir")
	  . "/conf/server.xml";
	$initPropertiesFile =
	    escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
	  . $globalConfig->param("$lcApplication.webappDir")
	  . "/WEB-INF/classes/$lcApplication-init.properties";
	$javaMemParameterFile =
	    escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
	  . $globalConfig->param("$lcApplication.tomcatDir")
	  . "/bin/setenv.sh";

	print "Creating backup of config files...\n\n";
	$log->info("$subname: Backing up config files.");

	backupFile( $serverXMLFile, $osUser );

	backupFile( $initPropertiesFile, $osUser );

	backupFile( $javaMemParameterFile, $osUser );

	print "Applying custom context to $application...\n\n";
	setCustomCrowdContext();

	print "Applying port numbers to server config...\n\n";

	#Update the server config with the configured connector port
	$log->info( "$subname: Updating the connector port in " . $serverXMLFile );
	updateXMLAttribute( $serverXMLFile, "///Connector", "port",
		$globalConfig->param("$lcApplication.connectorPort") );

	#Update the server config with the configured server port
	$log->info( "$subname: Updating the server port in " . $serverXMLFile );
	updateXMLAttribute( $serverXMLFile, "/Server", "port",
		$globalConfig->param("$lcApplication.serverPort") );

	#Update the server config with reverse proxy configuration
	$log->info( "$subname: Updating the reverse proxy configuration in "
		  . $serverXMLFile );
	print "Applying Apache proxy parameters to config...\n\n";
	if ( $globalConfig->param("general.apacheProxy") eq "TRUE" ) {
		if ( $globalConfig->param("general.apacheProxySingleDomain") eq "TRUE" )
		{
			updateXMLAttribute( $serverXMLFile, "///Connector", "proxyName",
				$globalConfig->param("general.apacheProxyHost") );

			if ( $globalConfig->param("general.apacheProxySSL") eq "TRUE" ) {
				updateXMLAttribute( $serverXMLFile, "///Connector", "scheme",
					"https" );
			}
			else {
				updateXMLAttribute( $serverXMLFile, "///Connector", "scheme",
					"http" );
			}
			updateXMLAttribute( $serverXMLFile, "///Connector", "secure",
				"false" );
			updateXMLAttribute( $serverXMLFile, "///Connector", "proxyPort",
				$globalConfig->param("general.apacheProxyPort") );
		}
		else {
			updateXMLAttribute( $serverXMLFile, "///Connector", "proxyName",
				$globalConfig->param("$lcApplication.apacheProxyHost") );

			if ( $globalConfig->param("$lcApplication.apacheProxySSL") eq
				"TRUE" )
			{
				updateXMLAttribute( $serverXMLFile, "///Connector", "scheme",
					"https" );
			}
			else {
				updateXMLAttribute( $serverXMLFile, "///Connector", "scheme",
					"http" );
			}
			updateXMLAttribute( $serverXMLFile, "///Connector", "secure",
				"false" );
			updateXMLAttribute( $serverXMLFile, "///Connector", "proxyPort",
				$globalConfig->param("$lcApplication.apacheProxyPort") );
		}
	}

	print "Applying home directory location to config...\n\n";

	#Edit Crowd config file to reference homedir
	$log->info( "$subname: Applying homedir in " . $initPropertiesFile );
	print "Applying home directory to config...\n\n";
	updateLineInFile(
		$initPropertiesFile,
		"crowd.home",
		"$lcApplication.home="
		  . escapeFilePath( $globalConfig->param("$lcApplication.dataDir") ),
		"#crowd.home=/var/crowd-home"
	);

	@parameterNull = $globalConfig->param("$lcApplication.javaParams");
	if (   ( $#parameterNull == -1 )
		|| $globalConfig->param("$lcApplication.javaParams") eq ""
		|| $globalConfig->param("$lcApplication.javaParams") eq "default" )
	{
		$javaOptsValue = "NOJAVAOPTSCONFIGSPECIFIED";
	}
	else {
		$javaOptsValue = "CONFIGSPECIFIED";
	}

	#Apply the JavaOpts configuration (if any)
	print "Applying Java_Opts configuration to install...\n\n";
	if ( $javaOptsValue ne "NOJAVAOPTSCONFIGSPECIFIED" ) {
		updateJavaOpts(
			escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
			  . $globalConfig->param( $lcApplication . ".tomcatDir" )
			  . "/bin/setenv.sh",
			"JAVA_OPTS",
			getConfigItem( "$lcApplication.javaParams", $globalConfig )
		);
	}

	#Apply Catalina Opts to Install
	@parameterNull = $globalConfig->param("$lcApplication.catalinaOpts");
	if (   ( $#parameterNull == -1 )
		|| $globalConfig->param("$lcApplication.catalinaOpts") eq ""
		|| $globalConfig->param("$lcApplication.catalinaOpts") eq "default" )
	{
		$catalinaOptsValue = "NOCATALINAOPTSCONFIGSPECIFIED";
	}
	else {
		$catalinaOptsValue = "CONFIGSPECIFIED";
	}

	print "Applying CATALINA_OPTS configuration to install...\n\n";
	if ( $javaOptsValue ne "NOCATALINAOPTSCONFIGSPECIFIED" ) {
		updateCatalinaOpts(
			$application,
			escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
			  . $globalConfig->param( $lcApplication . ".tomcatDir" )
			  . "/bin/setenv.sh",
			"CATALINA_OPTS=",
			getConfigItem( "$lcApplication.catalinaOpts", $globalConfig )
		);
	}

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

	generateInitD(
		$application,
		$osUser,
		escapeFilePath( $globalConfig->param("$lcApplication.installDir") ),
		"start_crowd.sh",
		"stop_crowd.sh",
		$globalConfig->param("$lcApplication.processSearchParameter1"),
		$globalConfig->param("$lcApplication.processSearchParameter2")
	);

	#Finally run generic post install tasks
	postInstallGeneric($application);
}

########################################
#Uninstall Crowd                       #
########################################
sub uninstallCrowd {
	my $application = "Crowd";
	uninstallGeneric($application);
}

########################################
#Upgrade Crowd                         #
########################################
sub upgradeCrowd {
	my $application = "Crowd";
	my $osUser;
	my $lcApplication;
	my $downloadArchivesUrl =
	  "http://www.atlassian.com/software/crowd/download-archive";
	my $serverXMLFile;
	my $initPropertiesFile;
	my $javaMemParameterFile;
	my @parameterNull;
	my $javaOptsValue;
	my $catalinaOptsValue;
	my @requiredConfigItems;
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	#Set up list of config items that are requred for this install to run
	$lcApplication       = lc($application);
	@requiredConfigItems = (
		"crowd.appContext",              "crowd.enable",
		"crowd.dataDir",                 "crowd.installDir",
		"crowd.runAsService",            "crowd.serverPort",
		"crowd.connectorPort",           "crowd.osUser",
		"crowd.tomcatDir",               "crowd.webappDir",
		"crowd.javaMinMemory",           "crowd.javaMaxMemory",
		"crowd.javaMaxPermSize",         "crowd.installedVersion",
		"crowd.processSearchParameter1", "crowd.processSearchParameter2"
	);

	if ( $globalConfig->param("general.apacheProxy") eq "TRUE" ) {
		if (
			$globalConfig->param("general.apacheProxySingleDomain") eq "FALSE" )
		{
			push( @requiredConfigItems, "crowd.apacheProxyPort" );
			push( @requiredConfigItems, "crowd.apacheProxySSL" );
			push( @requiredConfigItems, "crowd.apacheProxyHost" );
		}
	}

	#bugFix for versions prior to v0.1.6 see [#ATLASMGR-265]
	if ( $globalConfig->param("crowd.processSearchParameter2") eq
		"Dcatalina.base=/drive2/opt/crowd/apache-tomcat" )
	{

		#force the value to NULL so that config will need to be regenerated.
		$globalConfig->param( "crowd.processSearchParameter2", "" );

		#Write config and reload
		$log->info("Writing out config file to disk.");
		$globalConfig->write($configFile);
		loadSuiteConfig();
	}

	#Force update config items for search parameters
	$globalConfig->param( "$lcApplication.processSearchParameter1", "java" );
	$globalConfig->param( "$lcApplication.processSearchParameter2",
		    "Dcatalina.base="
		  . $globalConfig->param("$lcApplication.installDir")
		  . $globalConfig->param("$lcApplication.tomcatDir") );
	$globalConfig->write($configFile);
	loadSuiteConfig();

	#Run generic upgrader steps
	upgradeGeneric( $application, $downloadArchivesUrl, \@requiredConfigItems );
	$osUser = $globalConfig->param("$lcApplication.osUser")
	  ; #we get this after install in CASE the upgrader changes the configured user in future

	#Perform application specific configuration
	print "Applying configuration settings to the install, please wait...\n\n";

	$serverXMLFile =
	    escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
	  . $globalConfig->param("$lcApplication.tomcatDir")
	  . "/conf/server.xml";
	$initPropertiesFile =
	    escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
	  . $globalConfig->param("$lcApplication.webappDir")
	  . "/WEB-INF/classes/$lcApplication-init.properties";
	$javaMemParameterFile =
	    escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
	  . $globalConfig->param("$lcApplication.tomcatDir")
	  . "/bin/setenv.sh";

	print "Creating backup of config files...\n\n";
	$log->info("$subname: Backing up config files.");

	backupFile( $serverXMLFile, $osUser );

	backupFile( $initPropertiesFile, $osUser );

	backupFile( $javaMemParameterFile, $osUser );

	print "Applying custom context to $application...\n\n";
	setCustomCrowdContext();

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

	#Update the server config with reverse proxy configuration
	$log->info( "$subname: Updating the reverse proxy configuration in "
		  . $serverXMLFile );
	print "Applying Apache proxy parameters to config...\n\n";
	if ( $globalConfig->param("general.apacheProxy") eq "TRUE" ) {
		if ( $globalConfig->param("general.apacheProxySingleDomain") eq "TRUE" )
		{
			updateXMLAttribute( $serverXMLFile, "///Connector", "proxyName",
				$globalConfig->param("general.apacheProxyHost") );

			if ( $globalConfig->param("general.apacheProxySSL") eq "TRUE" ) {
				updateXMLAttribute( $serverXMLFile, "///Connector", "scheme",
					"https" );
			}
			else {
				updateXMLAttribute( $serverXMLFile, "///Connector", "scheme",
					"http" );
			}
			updateXMLAttribute( $serverXMLFile, "///Connector", "secure",
				"false" );
			updateXMLAttribute( $serverXMLFile, "///Connector", "proxyPort",
				$globalConfig->param("general.apacheProxyPort") );
		}
		else {
			updateXMLAttribute( $serverXMLFile, "///Connector", "proxyName",
				$globalConfig->param("$lcApplication.apacheProxyHost") );

			if ( $globalConfig->param("$lcApplication.apacheProxySSL") eq
				"TRUE" )
			{
				updateXMLAttribute( $serverXMLFile, "///Connector", "scheme",
					"https" );
			}
			else {
				updateXMLAttribute( $serverXMLFile, "///Connector", "scheme",
					"http" );
			}
			updateXMLAttribute( $serverXMLFile, "///Connector", "secure",
				"false" );
			updateXMLAttribute( $serverXMLFile, "///Connector", "proxyPort",
				$globalConfig->param("$lcApplication.apacheProxyPort") );
		}
	}

	print "Applying home directory location to config...\n\n";

	#Edit Crowd config file to reference homedir
	$log->info( "$subname: Applying homedir in " . $initPropertiesFile );
	print "Applying home directory to config...\n\n";
	updateLineInFile(
		$initPropertiesFile,
		"crowd.home",
		"$lcApplication.home="
		  . escapeFilePath( $globalConfig->param("$lcApplication.dataDir") ),
		"#crowd.home=/var/crowd-home"
	);

	@parameterNull = $globalConfig->param("$lcApplication.javaParams");
	if (   ( $#parameterNull == -1 )
		|| $globalConfig->param("$lcApplication.javaParams") eq ""
		|| $globalConfig->param("$lcApplication.javaParams") eq "default" )
	{
		$javaOptsValue = "NOJAVAOPTSCONFIGSPECIFIED";
	}
	else {
		$javaOptsValue = "CONFIGSPECIFIED";
	}

	#Apply the JavaOpts configuration (if any)
	print "Applying Java_Opts configuration to install...\n\n";
	if ( $javaOptsValue ne "NOJAVAOPTSCONFIGSPECIFIED" ) {
		updateJavaOpts(
			escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
			  . $globalConfig->param( $lcApplication . ".tomcatDir" )
			  . "/bin/setenv.sh",
			"JAVA_OPTS",
			getConfigItem( "$lcApplication.javaParams", $globalConfig )
		);
	}

	#Apply Catalina Opts to Install
	@parameterNull = $globalConfig->param("$lcApplication.catalinaOpts");
	if (   ( $#parameterNull == -1 )
		|| $globalConfig->param("$lcApplication.catalinaOpts") eq ""
		|| $globalConfig->param("$lcApplication.catalinaOpts") eq "default" )
	{
		$catalinaOptsValue = "NOCATALINAOPTSCONFIGSPECIFIED";
	}
	else {
		$catalinaOptsValue = "CONFIGSPECIFIED";
	}

	print "Applying CATALINA_OPTS configuration to install...\n\n";
	if ( $javaOptsValue ne "NOCATALINAOPTSCONFIGSPECIFIED" ) {
		updateCatalinaOpts(
			$application,
			escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
			  . $globalConfig->param( $lcApplication . ".tomcatDir" )
			  . "/bin/setenv.sh",
			"CATALINA_OPTS=",
			getConfigItem( "$lcApplication.catalinaOpts", $globalConfig )
		);
	}

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

	#Re-Generate the init.d file in case any config parameters changed.
	print
"Setting up initd files and run as a service (if configured) please wait...\n\n";
	$log->info("$subname: Generating init.d file for $application.");
	generateInitD(
		$application,
		$osUser,
		escapeFilePath( $globalConfig->param("$lcApplication.installDir") ),
		"start_crowd.sh",
		"stop_crowd.sh",
		$globalConfig->param("$lcApplication.processSearchParameter1"),
		$globalConfig->param("$lcApplication.processSearchParameter2")
	);

	#Finally run generic post install tasks
	postUpgradeGeneric($application);
}

#######################################################################
#END CROWD MANAGER FUNCTIONS                                          #
#######################################################################

#######################################################################
#BEGIN FISHEYE MANAGER FUNCTIONS                                      #
#######################################################################

########################################
#getExistingFisheyeConfig              #
########################################
sub getExistingFisheyeConfig {
	my $cfg;
	my $defaultValue;
	my $application   = "Fisheye";
	my $mode          = "CREATE";
	my $lcApplication = lc($application);
	my $subname       = ( caller(0) )[3];
	my $serverConfigFile;
	my $serverSetEnvFile;
	my $externalCrowdInstance;
	my @parameterNull;
	my $input;
	my $LOOP = 0;
	my $returnValue;

	$log->debug("BEGIN: $subname");

	$cfg = $_[0];

	while ( $LOOP == 0 ) {

		#Ask for install dir
		genConfigItem(
			$mode,
			$cfg,
			"$lcApplication.installDir",
"Please enter the directory $application is currently installed into.",
			"",
			'(?!^.*/$)^(/.*)',
"The input you entered was not in the valid format of '/folder'. Please ensure you enter the absolute path with a "
			  . "leading '/' and NO trailing '/'.\n\n"
		);

		if ( -d escapeFilePath( $cfg->param("$lcApplication.installDir") ) ) {
			$LOOP = 1;    #break loop as directory exists
			$log->info( "$subname: Directory "
				  . escapeFilePath( $cfg->param("$lcApplication.installDir") )
				  . " exists. Proceeding..." );
			print "The directory "
			  . escapeFilePath( $cfg->param("$lcApplication.installDir") )
			  . " exists. Proceeding...\n\n";
		}
		else {
			print "The directory "
			  . escapeFilePath( $cfg->param("$lcApplication.installDir") )
			  . " does not exist. Please try again.\n\n";
			$log->info( "The directory "
				  . escapeFilePath( $cfg->param("$lcApplication.installDir") )
				  . " does not exist. Please try again." );
		}
	}

	#Ask for current installed version
	genConfigItem(
		$mode,
		$cfg,
		"$lcApplication.installedVersion",
		"Please enter the version of $application that is currently installed.",
		"",
		'^[0-9]+\.([0-9]+|[0-9]+\.[0-9]+)$',
"The input you entered was not in the valid format of 'x.x.x or x.x' (where x is a version number). Please ensure you enter the version number correctly "
		  . "\n\n"
	);

	genConfigItem(
		$mode,
		$cfg,
		"$lcApplication.javaParams",
"Enter any additional parameters currently added to the JAVA RUN_OPTS for your $application install. Just press enter if you have none.",
		"",
		"",
		""
	);

	if (   $cfg->param("general.apacheProxy") eq "TRUE"
		&& $cfg->param("general.apacheProxySingleDomain") eq "FALSE" )
	{
		genConfigItem(
			$mode,
			$cfg,
			"fisheye.apacheProxyHost",
"Please enter the base URL Fisheye currently runs on (i.e. the proxyName such as yourdomain.com).",
			"",
			$hostnameRegex,
"The input you entered was not in the valid format of 'yourdomain.com' or 'subdomain.yourdomain.com'. Please try again.\n\n"
		);

		genBooleanConfigItem( $mode, $cfg, "fisheye.apacheProxySSL",
			"Do you currently run Fisheye over SSL.", "no" );

		genConfigItem(
			$mode,
			$cfg,
			"fisheye.apacheProxyPort",
"Please enter the port number that Apache currently serves Fisheye on (80 for HTTP, 443 for HTTPS in standard situations).",
			"80",
			'^([0-9]*)$',
"The input you entered was not a valid port number, please try again.\n\n"
		);
	}

	$serverSetEnvFile =
	  escapeFilePath( $cfg->param("$lcApplication.installDir") )
	  . "/bin/fisheyectl.sh";

	$serverConfigFile =
	  escapeFilePath( $cfg->param("$lcApplication.installDir") )
	  . "/config.xml";

	genBooleanConfigItem(
		$mode,
		$cfg,
		"$lcApplication.runAsService",
"Does your $application instance run as a service (i.e. runs on boot)? yes/no.",
		"yes"
	);

	#GetCrowdConfig
	@parameterNull = $cfg->param("general.externalCrowdInstance");

	if ( $#parameterNull == -1 ) {
		$externalCrowdInstance = "FALSE";
	}
	else {
		$externalCrowdInstance = $cfg->param("general.externalCrowdInstance");
	}

	if (   $externalCrowdInstance eq "TRUE"
		|| $cfg->param("crowd.enable") eq "TRUE" )
	{
		genBooleanConfigItem(
			$mode,
			$cfg,
			"fisheye.crowdIntegration",
"Will you be using Crowd as the authentication backend for Fisheye? yes/no.",
			"yes"
		);
	}
	else {
		$cfg->param( "fisheye.crowdIntegration", "FALSE" );
		$cfg->param( "fisheye.crowdSSO",         "FALSE" );
	}

	print
"Please wait, attempting to get the $application data/home directory from it's config files...\n\n";
	$log->info(
"$subname: Attempting to get $application data directory from config file $serverConfigFile."
	);

	#get data/home directory
	$returnValue =
	  getEnvironmentVarsFromConfigFile( "/etc/environment", "FISHEYE_INST" );

	if ( $returnValue eq "NOTFOUND" ) {
		$log->info(
"$subname: Unable to locate $application data directory. Asking user for input."
		);
		genConfigItem(
			$mode,
			$cfg,
			"$lcApplication.dataDir",
"Unable to find the data directory in the expected location in the $application config. Please enter the directory $application"
			  . "'s data is *currently* stored in. Please note if this is in the install folder (i.e. no separate directory) please just enter the same folder name here.",
			"",
			'(?!^.*/$)^(/.*)',
"The input you entered was not in the valid format of '/folder'. Please ensure you enter the absolute path with a "
			  . "leading '/' and NO trailing '/'.\n\n"
		);
	}
	else {
		$cfg->param( "$lcApplication.dataDir", $returnValue );
		print
"$application data directory has been found successfully and added to the config file...\n\n";
		$log->info(
			"$subname: $application data directory found and added to config."
		);
	}

	#getContextFromFile
	$returnValue = "";

	print
"Please wait, attempting to get the $application context from it's config files...\n\n";
	$log->info(
"$subname: Attempting to get $application context from config file $serverConfigFile."
	);
	$returnValue =
	  getXMLAttribute( $serverConfigFile, "web-server", "context" );

	if ( $returnValue eq "NOTFOUND" ) {
		$log->info(
"$subname: Unable to locate $application context. Asking user for input."
		);
		genConfigItem(
			$mode,
			$cfg,
			"$lcApplication.appContext",
"Unable to find the context in the expected location in the $application config. $application does not contain this information in it's config by default therefore we will need to get it from you. Please enter the context that $application currently runs under (i.e. /fisheye). Write NULL to blank out the context.",
			"/fisheye",
			'(?!^.*/$)^(/.*)',
"The input you entered was not in the valid format of '/folder'. Please ensure you enter the path with a "
			  . "leading '/' and NO trailing '/'.\n\n"
		);
	}
	else {
		if ( $returnValue eq "" ) {
			$returnValue = "NULL";
		}
		$cfg->param( "$lcApplication.appContext", $returnValue );
		print
"$application context has been found successfully and added to the config file...\n\n";
		$log->info("$subname: $application context found and added to config.");
	}

	$returnValue = "";

	print
"Please wait, attempting to get the $application connectorPort from it's config files...\n\n";
	$log->info(
"$subname: Attempting to get $application connectorPort from config file $serverConfigFile."
	);

	#Get connector port from file
	$returnValue = getXMLAttribute( $serverConfigFile, "//http", "bind" );

	#strip leading : off the return value if it exists
	$returnValue =~ s/://g;

	if ( $returnValue eq "NOTFOUND" ) {
		$log->info(
"$subname: Unable to locate $application connectorPort. Asking user for input."
		);
		genConfigItem(
			$mode,
			$cfg,
			"$lcApplication.connectorPort",
"Unable to find the connector port in the expected location in the $application config. Please enter the Connector port $application *currently* runs on (note this is the port you will access in the browser).",
			"8060",
			'^([0-9]*)$',
"The port number you entered contained invalid characters. Please ensure you enter only digits.\n\n"
		);
	}
	else {
		$cfg->param( "$lcApplication.connectorPort", $returnValue );
		print
"$application connectorPort has been found successfully and added to the config file...\n\n";
		$log->info(
			"$subname: $application connectorPort found and added to config.");
	}

	$returnValue = "";

	print
"Please wait, attempting to get the $application serverPort from it's config files...\n\n";
	$log->info(
"$subname: Attempting to get $application serverPort from config file $serverConfigFile."
	);

	#Get connector port from file
	$returnValue =
	  getXMLAttribute( $serverConfigFile, "/config", "control-bind" );

	#strip leading 127.0.0.1: off the return value if it exists
	$returnValue =~ s/127.0.0.1://g;

	if ( $returnValue eq "NOTFOUND" ) {
		$log->info(
"$subname: Unable to locate $application serverPort. Asking user for input."
		);
		genConfigItem(
			$mode,
			$cfg,
			"$lcApplication.serverPort",
"Unable to find the server port in the expected location in the $application config. Please enter the Server port $application *currently* runs on (note this is the tomcat control port).",
			"8059",
			'^([0-9]*)$',
"The port number you entered contained invalid characters. Please ensure you enter only digits.\n\n"
		);
	}
	else {
		$cfg->param( "$lcApplication.serverPort", $returnValue );
		print
"$application serverPort has been found successfully and added to the config file...\n\n";
		$log->info(
			"$subname: $application serverPort found and added to config.");
	}

	$returnValue = "";

	print
"Please wait, attempting to get the $application Xms java memory parameter from it's config files...\n\n";
	$log->info(
"$subname: Attempting to get $application Xms java memory parameter from config file $serverConfigFile."
	);
	$returnValue =
	  getJavaMemParameter( $serverSetEnvFile, "FISHEYE_OPTS", "-Xms" );
	if ( $returnValue eq "NOTFOUND" ) {
		$log->info(
"$subname: Unable to locate $application Xms memory parameter. Asking user for input."
		);
		genConfigItem(
			$mode,
			$cfg,
			"$lcApplication.javaMinMemory",
"Unable to find the java Xms memory parameter in the expected location in the $application config. $application does not always have this by default hence we will need you to input this. Please enter the minimum amount of memory *currently* assigned to $application.",
			"256m",
			'^([0-9]*m)$',
"The memory value you entered is in an invalid format. Please ensure you use the format '1234m'. (i.e. '256m')"
		);
	}
	else {
		$cfg->param( "$lcApplication.javaMinMemory", $returnValue );
		print
"$application Xms java memory parameter has been found successfully and added to the config file...\n\n";
		$log->info(
"$subname: $application Xms java memory parameter found and added to config."
		);
	}

	$returnValue = "";

	print
"Please wait, attempting to get the $application Xmx java memory parameter from it's config files...\n\n";
	$log->info(
"$subname: Attempting to get $application Xmx java memory parameter from config file $serverConfigFile."
	);
	$returnValue =
	  getJavaMemParameter( $serverSetEnvFile, "FISHEYE_OPTS", "-Xmx" );
	if ( $returnValue eq "NOTFOUND" ) {
		$log->info(
"$subname: Unable to locate $application Xmx memory parameter. Asking user for input."
		);
		genConfigItem(
			$mode,
			$cfg,
			"$lcApplication.javaMaxMemory",
"Unable to find the java Xmx memory parameter in the expected location in the $application config. $application does not always have this by default hence we will need you to input this. Please enter the maximum amount of memory *currently* assigned to $application.",
			"512m",
			'^([0-9]*m)$',
"The memory value you entered is in an invalid format. Please ensure you use the format '1234m'. (i.e. '256m')"
		);
	}
	else {
		$cfg->param( "$lcApplication.javaMaxMemory", $returnValue );
		print
"$application Xmx java memory parameter has been found successfully and added to the config file...\n\n";
		$log->info(
"$subname: $application Xmx java memory parameter found and added to config."
		);
	}

	$returnValue = "";

	print
"Please wait, attempting to get the $application XX:MaxPermSize java memory parameter from it's config files...\n\n";
	$log->info(
"$subname: Attempting to get $application XX:MaxPermSize java memory parameter from config file $serverConfigFile."
	);
	$returnValue = getJavaMemParameter( $serverSetEnvFile, "FISHEYE_OPTS",
		"-XX:MaxPermSize=" );
	if ( $returnValue eq "NOTFOUND" ) {
		$log->info(
"$subname: Unable to locate $application XX:MaxPermSize memory parameter. Asking user for input."
		);
		genConfigItem(
			$mode,
			$cfg,
			"$lcApplication.javaMaxPermSize",
"Unable to find the java XX:MaxPermSize memory parameter in the expected location in the $application config. $application does not always have this by default hence we will need you to input this. Please enter the maximum amount of permGen memory *currently* assigned to $application.",
			"256m",
			'^([0-9]*m)$',
"The memory value you entered is in an invalid format. Please ensure you use the format '1234m'. (i.e. '256m')"
		);
	}
	else {
		$cfg->param( "$lcApplication.javaMaxPermSize", $returnValue );
		print
"$application XX:MaxPermSize java memory parameter has been found successfully and added to the config file...\n\n";
		$log->info(
"$subname: $application XX:MaxPermSize java memory parameter found and added to config."
		);
	}

	$returnValue = "";

	#getOSuser
	open( my $inputFileHandle,
		'<', escapeFilePath( $cfg->param("$lcApplication.installDir") ) )
	  or $log->logdie(
"Unable to open install dir for $application to test who owns it. Really this should never happen as we have already tested that the directory exists."
	  );
	my (
		$dev,   $ino,     $fileMode, $nlink, $uid,
		$gid,   $rdev,    $size,     $atime, $mtime,
		$ctime, $blksize, $blocks
	) = stat($inputFileHandle);
	$returnValue = getpwuid($uid);

	close $inputFileHandle;

	#confirmWithUserThatIsTheCorrectOSUser
	$input = getBooleanInput(
"We have detected that the user $application runs under is '$returnValue'. Is this correct? yes/no [yes]: "
	);
	print "\n";
	if ( $input eq "default" || $input eq "yes" ) {
		$cfg->param( "$lcApplication.osUser", $returnValue );
		print
		  "The osUser $returnValue has been added to the config file...\n\n";
		$log->info(
"$subname: User confirmed that the user $application runs under is $returnValue. This has been added to the config."
		);
	}
	else {
		genConfigItem(
			$mode,
			$cfg,
			"$lcApplication.osUser",
"In that case please enter the user that $application *currently* runs under.",
			"",
			'^([a-zA-Z0-9]*)$',
"The user you entered was in an invalid format. Please ensure you enter only letters and numbers without any spaces or other characters.\n\n"
		);
	}
	if (   $cfg->param("general.apacheProxy") eq "TRUE"
		&& $cfg->param("general.apacheProxySingleDomain") eq "FALSE" )
	{
		$returnValue = "";

		print
"Please wait, attempting to get the Apache proxy base hostname configuration for $application from the configuration files...\n\n";
		$log->info(
"$subname: Attempting to get $application proxyName from config file $serverConfigFile."
		);
		$returnValue =
		  getXMLAttribute( $serverConfigFile, "//http", "proxy-host" );

		if ( $returnValue eq "NOTFOUND" ) {
			$log->info(
"$subname: Unable to locate $application proxyName. Asking user for input."
			);
			genConfigItem(
				$mode,
				$cfg,
				"$lcApplication.apacheProxyHost",
"Unable to find the base hostname attribute in the expected location in the $application config. Please enter the base URL that will be serving the site (i.e. the proxyName such as yourdomain.com).",
				"",
				$hostnameRegex,
"The input you entered was not in the valid format of 'yourdomain.com' or 'subdomain.yourdomain.com'. Please try again.\n\n"
			);
		}
		else {
			$cfg->param( "$lcApplication.apacheProxyHost", $returnValue );
			print
"$application base hostname has been found successfully and added to the config file...\n\n";
			$log->info(
"$subname: $application base hostname found and added to config."
			);
		}

		$returnValue = "";

		print
"Please wait, attempting to get the Apache proxy scheme configuration for $application from the configuration files...\n\n";
		$log->info(
"$subname: Attempting to get $application proxy scheme from config file $serverConfigFile."
		);
		$returnValue =
		  getXMLAttribute( $serverConfigFile, "//http", "proxy-scheme" );

		if ( $returnValue eq "NOTFOUND" ) {
			$log->info(
"$subname: Unable to locate $application proxy scheme. Asking user for input."
			);
			genBooleanConfigItem(
				$mode,
				$cfg,
				"$lcApplication.apacheProxySSL",
"Unable to locate the Apache proxy scheme configuration in $application config. Will you be running $application over SSL.",
				"no"
			);
		}
		else {
			if ( $returnValue eq "http" ) {
				$log->info(
"$subname: return value for Apache Proxy Scheme config is 'http'."
				);
				$cfg->param( "$lcApplication.apacheProxySSL", "FALSE" );
			}
			elsif ( $returnValue eq "https" ) {
				$log->info(
"$subname: return value for Apache Proxy Scheme config is 'http'."
				);
				$cfg->param( "$lcApplication.apacheProxySSL", "TRUE" );
			}
			else {
				$log->info(
"$subname: return value for Apache Proxy Scheme config is 'UNKNOWN' This is not good."
				);
				$cfg->param( "$lcApplication.apacheProxySSL", "UNKNOWN" );
			}
			print
"$application Apache Proxy scheme has been found successfully and added to the config file...\n\n";
			$log->info(
				"$subname: $application proxy scheme found and added to config."
			);
		}

		$returnValue = "";

		print
"Please wait, attempting to get the Apache proxy port configuration for $application from the configuration files...\n\n";
		$log->info(
"$subname: Attempting to get $application proxyPort from config file $serverConfigFile."
		);
		$returnValue =
		  getXMLAttribute( $serverConfigFile, "//http", "proxy-port" );

		if ( $returnValue eq "NOTFOUND" ) {
			$log->info(
"$subname: Unable to locate $application proxyPort. Asking user for input."
			);
			genConfigItem(
				$mode,
				$cfg,
				"$lcApplication.apacheProxyPort",
"Unable to find the Apache proxy port attribute in the expected location in the $application config. Please enter the port number that Apache currently serves on (80 for HTTP, 443 for HTTPS in standard situations).",
				"80/443",
				'^([0-9]*)$',
"The input you entered was not a valid port number, please try again.\n\n"
			);
		}
		else {
			$cfg->param( "$lcApplication.apacheProxyPort", $returnValue );
			print
"$application base hostname has been found successfully and added to the config file...\n\n";
			$log->info(
"$subname: $application base hostname found and added to config."
			);
		}
	}

	#Set up some defaults for Fisheye
	$cfg->param( "fisheye.tomcatDir", "" )
	  ;    #we leave these blank deliberately due to the way Fishey works
	$cfg->param( "fisheye.webappDir", "" )
	  ;    #we leave these blank deliberately due to the way Fishey works
	$cfg->param( "fisheye.processSearchParameter1", "java" );
	$cfg->param( "fisheye.processSearchParameter2",
		"Dfisheye.inst=" . $cfg->param("fisheye.installDir") );
	$cfg->param( "$lcApplication.enable", "TRUE" );

	$cfg->write($configFile);
	loadSuiteConfig();

	print
"We now have the $application config and it has been written to the config file. Please press enter to continue.\n";
	$input = <STDIN>;
}

########################################
#GenerateFisheyeConfig                 #
########################################
sub generateFisheyeConfig {
	my $cfg;
	my $mode;
	my $defaultValue;
	my $externalCrowdInstance;
	my @parameterNull;
	my $application = "Fisheye";
	my $subname     = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	$mode = $_[0];
	$cfg  = $_[1];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_mode", $mode );

	genConfigItem(
		$mode,
		$cfg,
		"fisheye.installDir",
		"Please enter the directory Fisheye will be installed into.",
		$cfg->param("general.rootInstallDir") . "/fisheye",
		'(?!^.*/$)^(/.*)',
"The input you entered was not in the valid format of '/folder'. Please ensure you enter the absolute path with a "
		  . "leading '/' and NO trailing '/'.\n\n"
	);

	genConfigItem(
		$mode,
		$cfg,
		"fisheye.dataDir",
		"Please enter the directory Fisheye's data will be stored in.",
		$cfg->param("general.rootDataDir") . "/fisheye",
		'(?!^.*/$)^(/.*)',
"The input you entered was not in the valid format of '/folder'. Please ensure you enter the absolute path with a "
		  . "leading '/' and NO trailing '/'.\n\n"
	);

	genConfigItem(
		$mode,
		$cfg,
		"fisheye.osUser",
		"Enter the user that Fisheye will run under.",
		"fisheye",
		'^([a-zA-Z0-9]*)$',
"The user you entered was in an invalid format. Please ensure you enter only letters and numbers without any spaces or other characters.\n\n"
	);

	genConfigItem(
		$mode,
		$cfg,
		"fisheye.appContext",
"Enter the context that Fisheye should run under (i.e. /fisheye). Write NULL to blank out the context.",
		"/fisheye",
		'(?!^.*/$)^(/.*)',
"The input you entered was not in the valid format of '/folder'. Please ensure you enter the path with a "
		  . "leading '/' and NO trailing '/'.\n\n"
	);

	genConfigItem(
		$mode,
		$cfg,
		"fisheye.connectorPort",
"Please enter the Connector port Fisheye will run on (note this is the port you will access in the browser).",
		"8060",
		'^([0-9]*)$',
"The port number you entered contained invalid characters. Please ensure you enter only digits.\n\n"
	);
	checkConfiguredPort( $application, "fisheye.connectorPort", $cfg );

	genConfigItem(
		$mode,
		$cfg,
		"fisheye.serverPort",
"Please enter the SERVER port Fisheye will run on (note this is the control port not the port you access in a browser).",
		"8059",
		'^([0-9]*)$',
"The port number you entered contained invalid characters. Please ensure you enter only digits.\n\n"
	);
	checkConfiguredPort( $application, "fisheye.serverPort", $cfg );

	genConfigItem(
		$mode,
		$cfg,
		"fisheye.javaParams",
"Enter any additional parameters you would like to add to the Java RUN_OPTS.",
		"",
		"",
		""
	);

	genConfigItem(
		$mode,
		$cfg,
		"fisheye.javaMinMemory",
"Enter the minimum amount of memory you would like to assign to Fisheye.",
		"128m",
		'^([0-9]*m)$',
"The memory value you entered is in an invalid format. Please ensure you use the format '1234m'. (i.e. '256m')"
	);

	genConfigItem(
		$mode,
		$cfg,
		"fisheye.javaMaxMemory",
"Enter the maximum amount of memory you would like to assign to Fisheye.",
		"512m",
		'^([0-9]*m)$',
"The memory value you entered is in an invalid format. Please ensure you use the format '1234m'. (i.e. '256m')"
	);

	genConfigItem(
		$mode,
		$cfg,
		"fisheye.javaMaxPermSize",
"Enter the amount of memory for the MAX_PERM_SIZE parameter that you would like to assign to Fisheye.",
		"256m",
		'^([0-9]*m)$',
"The memory value you entered is in an invalid format. Please ensure you use the format '1234m'. (i.e. '256m')"
	);

	if (   $cfg->param("general.apacheProxy") eq "TRUE"
		&& $cfg->param("general.apacheProxySingleDomain") eq "FALSE" )
	{
		genConfigItem(
			$mode,
			$cfg,
			"fisheye.apacheProxyHost",
"Please enter the base URL that will be serving the site (i.e. the proxyName such as yourdomain.com).",
			"",
			$hostnameRegex,
"The input you entered was not in the valid format of 'yourdomain.com' or 'subdomain.yourdomain.com'. Please try again.\n\n"
		);

		genBooleanConfigItem( $mode, $cfg, "fisheye.apacheProxySSL",
			"Will you be running Fisheye over SSL.", "no" );

		genConfigItem(
			$mode,
			$cfg,
			"fisheye.apacheProxyPort",
"Please enter the port number that Apache will serve on (80 for HTTP, 443 for HTTPS in standard situations).",
			"80",
			'^([0-9]*)$',
"The input you entered was not a valid port number, please try again.\n\n"
		);
	}

	genBooleanConfigItem( $mode, $cfg, "fisheye.runAsService",
		"Would you like to run Fisheye as a service? yes/no.", "yes" );

	#GetCrowdConfig
	@parameterNull = $cfg->param("general.externalCrowdInstance");

	if ( $#parameterNull == -1 ) {
		$externalCrowdInstance = "FALSE";
	}
	else {
		$externalCrowdInstance = $cfg->param("general.externalCrowdInstance");
	}

	if (   $externalCrowdInstance eq "TRUE"
		|| $cfg->param("crowd.enable") eq "TRUE" )
	{
		genBooleanConfigItem(
			$mode,
			$cfg,
			"fisheye.crowdIntegration",
"Will you be using Crowd as the authentication backend for Fisheye? yes/no.",
			"yes"
		);
	}
	else {
		$cfg->param( "fisheye.crowdIntegration", "FALSE" );
		$cfg->param( "fisheye.crowdSSO",         "FALSE" );
	}

	#Set up some defaults for Fisheye
	$cfg->param( "fisheye.tomcatDir", "" )
	  ;    #we leave these blank deliberately due to the way Fishey works
	$cfg->param( "fisheye.webappDir", "" )
	  ;    #we leave these blank deliberately due to the way Fishey works
	$cfg->param( "fisheye.processSearchParameter1", "java" );
	$cfg->param( "fisheye.processSearchParameter2",
		"Dfisheye.inst=" . $cfg->param("fisheye.dataDir") );

	$cfg->param( "fisheye.enable", "TRUE" );
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
	my @parameterNull;
	my $javaOptsValue;
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	#Set up list of config items that are requred for this install to run
	$lcApplication       = lc($application);
	@requiredConfigItems = (
		"fisheye.appContext",              "fisheye.enable",
		"fisheye.dataDir",                 "fisheye.installDir",
		"fisheye.runAsService",            "fisheye.osUser",
		"fisheye.serverPort",              "fisheye.connectorPort",
		"fisheye.javaMinMemory",           "fisheye.javaMaxMemory",
		"fisheye.javaMaxPermSize",         "fisheye.processSearchParameter1",
		"fisheye.processSearchParameter2", "fisheye.crowdIntegration"
	);

	if ( $globalConfig->param("general.apacheProxy") eq "TRUE" ) {
		if (
			$globalConfig->param("general.apacheProxySingleDomain") eq "FALSE" )
		{
			push( @requiredConfigItems, "fisheye.apacheProxyPort" );
			push( @requiredConfigItems, "fisheye.apacheProxySSL" );
			push( @requiredConfigItems, "fisheye.apacheProxyHost" );
		}
	}

	#Run generic installer steps
	installGeneric( $application, $downloadArchivesUrl, \@requiredConfigItems );
	$osUser = $globalConfig->param("$lcApplication.osUser")
	  ; #we get this after install in CASE the installer changes the configured user in future

	#Force update config items for search parameters
	$globalConfig->param( "$lcApplication.processSearchParameter1", "java" );
	$globalConfig->param( "$lcApplication.processSearchParameter2",
		"Dfisheye.inst=" . $globalConfig->param("fisheye.dataDir") );
	$globalConfig->write($configFile);
	loadSuiteConfig();

	#Perform application specific configuration
	print "Copying example config file, please wait...\n\n";
	$serverXMLFile =
	  escapeFilePath( $globalConfig->param("$lcApplication.dataDir") )
	  . "/config.xml";
	copyFile(
		escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
		  . "/config.xml",
		$serverXMLFile
	);
	chownFile( $osUser, $serverXMLFile );

	print "Applying configuration settings to the install, please wait...\n\n";

	print "Creating backup of config files...\n\n";
	$log->info("$subname: Backing up config files.");

	$javaMemParameterFile =
	  escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
	  . "/bin/fisheyectl.sh";
	backupFile( $serverXMLFile,        $osUser );
	backupFile( $javaMemParameterFile, $osUser );

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

	#Update the server config with reverse proxy configuration
	$log->info( "$subname: Updating the reverse proxy configuration in "
		  . $serverXMLFile );
	print "Applying Apache proxy parameters to config...\n\n";
	if ( $globalConfig->param("general.apacheProxy") eq "TRUE" ) {
		if ( $globalConfig->param("general.apacheProxySingleDomain") eq "TRUE" )
		{
			updateXMLAttribute( $serverXMLFile, "//http", "proxy-host",
				$globalConfig->param("general.apacheProxyHost") );

			if ( $globalConfig->param("general.apacheProxySSL") eq "TRUE" ) {
				updateXMLAttribute( $serverXMLFile, "//http", "proxy-scheme",
					"https" );
			}
			else {
				updateXMLAttribute( $serverXMLFile, "//http", "proxy-scheme",
					"http" );
			}
			updateXMLAttribute( $serverXMLFile, "//http", "proxy-port",
				$globalConfig->param("general.apacheProxyPort") );
		}
		else {
			updateXMLAttribute( $serverXMLFile, "//http", "proxy-host",
				$globalConfig->param("$lcApplication.apacheProxyHost") );

			if ( $globalConfig->param("$lcApplication.apacheProxySSL") eq
				"TRUE" )
			{
				updateXMLAttribute( $serverXMLFile, "//http", "proxy-scheme",
					"https" );
			}
			else {
				updateXMLAttribute( $serverXMLFile, "//http", "proxy-scheme",
					"http" );
			}
			updateXMLAttribute( $serverXMLFile, "//http", "proxy-port",
				$globalConfig->param("$lcApplication.apacheProxyPort") );
		}
	}

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

	@parameterNull = $globalConfig->param("$lcApplication.javaParams");
	if (   ( $#parameterNull == -1 )
		|| $globalConfig->param("$lcApplication.javaParams") eq ""
		|| $globalConfig->param("$lcApplication.javaParams") eq "default" )
	{
		$javaOptsValue = "NOJAVAOPTSCONFIGSPECIFIED";
	}
	else {
		$javaOptsValue = "CONFIGSPECIFIED";
	}

	#Apply the JavaOpts configuration (if any)
	print "Applying Java_Opts configuration to install...\n\n";
	if ( $javaOptsValue ne "NOJAVAOPTSCONFIGSPECIFIED" ) {
		updateJavaOpts(
			escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
			  . "/bin/fisheyectl.sh",
			"FISHEYE_OPTS",
			getConfigItem( "$lcApplication.javaParams", $globalConfig )
		);

	}

	print "Configuration settings have been applied successfully.\n\n";

	#Run any additional steps
	my $environmentProfileFile = "/etc/environment";
	$log->info(
"$subname: Inserting the FISHEYE_INST variable into '$environmentProfileFile'"
		  . $serverXMLFile );
	print
	  "Inserting the FISHEYE_INST variable into '$environmentProfileFile'.\n\n";
	updateEnvironmentVars( $environmentProfileFile, "FISHEYE_INST",
		escapeFilePath( $globalConfig->param("$lcApplication.dataDir") ) );

   #Also add to fisheyectl.sh as sometimes /etc/environment doesnt work reliably
	$log->info(
"$subname: Inserting the FISHEYE_INST variable into '$javaMemParameterFile'"
		  . $javaMemParameterFile );
	print
	  "Inserting the FISHEYE_INST variable into '$javaMemParameterFile'.\n\n";
	updateEnvironmentVars( $javaMemParameterFile, "FISHEYE_INST",
		escapeFilePath( $globalConfig->param("$lcApplication.dataDir") ) );
	createOrUpdateLineInFile(
		$javaMemParameterFile,
		"export FISHEYE_INST=",
		"export FISHEYE_INST="
		  . escapeFilePath( $globalConfig->param("$lcApplication.dataDir") ),
		"#!/bin/sh"
	);

	#Generate the init.d file
	print
"Setting up initd files and run as a service (if configured) please wait...\n\n";
	$log->info("$subname: Generating init.d file for $application.");

	generateInitD(
		$application,
		$osUser,
		escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
		  . "/bin/",
		"start.sh",
		"stop.sh",
		$globalConfig->param("$lcApplication.processSearchParameter1"),
		$globalConfig->param("$lcApplication.processSearchParameter2")
	);

	postInstallGeneric($application);
}

########################################
#Uninstall Fisheye                     #
########################################
sub uninstallFisheye {
	my $application = "Fisheye";
	uninstallGeneric($application);
}

########################################
#Upgrade Fisheye                       #
########################################
sub upgradeFisheye {
	my $application = "Fisheye";
	my $osUser;
	my $lcApplication;
	my $downloadArchivesUrl =
	  "http://www.atlassian.com/software/fisheye/download-archives";
	my $serverXMLFile;
	my $initPropertiesFile;
	my $javaMemParameterFile;
	my @requiredConfigItems;
	my @parameterNull;
	my $javaOptsValue;
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	#Set up list of config items that are requred for this install to run
	$lcApplication       = lc($application);
	@requiredConfigItems = (
		"fisheye.appContext",              "fisheye.enable",
		"fisheye.dataDir",                 "fisheye.installDir",
		"fisheye.runAsService",            "fisheye.osUser",
		"fisheye.serverPort",              "fisheye.connectorPort",
		"fisheye.javaMinMemory",           "fisheye.javaMaxMemory",
		"fisheye.javaMaxPermSize",         "fisheye.processSearchParameter1",
		"fisheye.processSearchParameter2", "fisheye.crowdIntegration"
	);

	if ( $globalConfig->param("general.apacheProxy") eq "TRUE" ) {
		if (
			$globalConfig->param("general.apacheProxySingleDomain") eq "FALSE" )
		{
			push( @requiredConfigItems, "fisheye.apacheProxyPort" );
			push( @requiredConfigItems, "fisheye.apacheProxySSL" );
			push( @requiredConfigItems, "fisheye.apacheProxyHost" );
		}
	}

   #Separate data directory out in case it still exists in the install directory
	if ( $globalConfig->param("$lcApplication.installDir") eq
		$globalConfig->param("$lcApplication.dataDir") )
	{

		#Data directory is still in the install directory. Lets move it out.
		$log->info(
"$subname: It appears Fisheye data still exists in the install dir. Separating this out."
		);
		print
"It appears the Fisheye directory still exists in the install directory. Separating this out...\n\n";
		createAndChownDirectory(
			$globalConfig->param("general.rootDataDir") . "/fisheye",
			$globalConfig->param("$lcApplication.osUser")
		);
		copyFile(
			$globalConfig->param("$lcApplication.installDir") . "/config.xml",
			$globalConfig->param("general.rootDataDir") . "/fisheye/config.xml"
		);
		copyDirectory(
			$globalConfig->param("$lcApplication.installDir") . "/var",
			$globalConfig->param("general.rootDataDir") . "/fisheye/var"
		);
		copyDirectory(
			$globalConfig->param("$lcApplication.installDir") . "/cache",
			$globalConfig->param("general.rootDataDir") . "/fisheye/cache"
		);

		$globalConfig->param( "$lcApplication.dataDir",
			$globalConfig->param("general.rootDataDir") . "/fisheye" );
		$log->info("Writing out config file to disk.");
		$globalConfig->write($configFile);
		loadSuiteConfig();

		$log->info( "$subname: Fisheye data directory created in "
			  . $globalConfig->param("general.rootDataDir")
			  . "/fisheye. Config updated and now ready to upgrade." );
		print "Fisheye data directory created in "
		  . $globalConfig->param("general.rootDataDir")
		  . "/fisheye Config updated and now ready to upgrade.\n\n";
	}

	#Force update config items for search parameters
	$globalConfig->param( "$lcApplication.processSearchParameter1", "java" );
	$globalConfig->param( "$lcApplication.processSearchParameter2",
		"Dfisheye.inst=" . $globalConfig->param("fisheye.dataDir") );
	$globalConfig->write($configFile);
	loadSuiteConfig();

	#Run generic upgrader steps
	upgradeGeneric( $application, $downloadArchivesUrl, \@requiredConfigItems );
	$osUser = $globalConfig->param("$lcApplication.osUser")
	  ; #we get this after install in CASE the upgrader changes the configured user in future

	#Perform application specific configuration
	print "Applying configuration settings to the install, please wait...\n\n";

	$javaMemParameterFile =
	  escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
	  . "/bin/fisheyectl.sh";

	#backupFilesFirst
	backupFile( $javaMemParameterFile, $osUser );

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

	@parameterNull = $globalConfig->param("$lcApplication.javaParams");
	if (   ( $#parameterNull == -1 )
		|| $globalConfig->param("$lcApplication.javaParams") eq ""
		|| $globalConfig->param("$lcApplication.javaParams") eq "default" )
	{
		$javaOptsValue = "NOJAVAOPTSCONFIGSPECIFIED";
	}
	else {
		$javaOptsValue = "CONFIGSPECIFIED";
	}

	#Apply the JavaOpts configuration (if any)
	print "Applying Java_Opts configuration to install...\n\n";
	if ( $javaOptsValue ne "NOJAVAOPTSCONFIGSPECIFIED" ) {
		updateJavaOpts(
			escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
			  . "/bin/fisheyectl.sh",
			"FISHEYE_OPTS",
			getConfigItem( "$lcApplication.javaParams", $globalConfig )
		);
	}

	print "Configuration settings have been applied successfully.\n\n";

	#Run any additional steps
	my $environmentProfileFile = "/etc/environment";
	$log->info(
"$subname: Updating the FISHEYE_INST variable in '$environmentProfileFile'"
	);
	print
	  "Updating the FISHEYE_INST variable in '$environmentProfileFile'.\n\n";
	updateEnvironmentVars( $environmentProfileFile, "FISHEYE_INST",
		escapeFilePath( $globalConfig->param("$lcApplication.dataDir") ) );

   #Also add to fisheyectl.sh as sometimes /etc/environment doesnt work reliably
	$log->info(
"$subname: Inserting the FISHEYE_INST variable into '$javaMemParameterFile'"
		  . $javaMemParameterFile );
	print
	  "Inserting the FISHEYE_INST variable into '$javaMemParameterFile'.\n\n";
	updateEnvironmentVars( $javaMemParameterFile, "FISHEYE_INST",
		escapeFilePath( $globalConfig->param("$lcApplication.dataDir") ) );
	createOrUpdateLineInFile(
		$javaMemParameterFile,
		"export FISHEYE_INST=",
		"export FISHEYE_INST="
		  . escapeFilePath( $globalConfig->param("$lcApplication.dataDir") ),
		"#!/bin/sh"
	);

	#Re-Generate the init.d file in case any config parameters changed.
	print
"Setting up initd files and run as a service (if configured) please wait...\n\n";
	$log->info("$subname: Generating init.d file for $application.");
	generateInitD(
		$application,
		$osUser,
		escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
		  . "/bin/",
		"start.sh",
		"stop.sh",
		$globalConfig->param("$lcApplication.processSearchParameter1"),
		$globalConfig->param("$lcApplication.processSearchParameter2")
	);

	#Finally run generic post install tasks
	postUpgradeGeneric($application);
}

#######################################################################
#END FISHEYE MANAGER FUNCTIONS                                        #
#######################################################################

#######################################################################
#BEGIN JIRA MANAGER FUNCTIONS                                         #
#######################################################################

########################################
#getExistingJIRAConfig                 #
########################################
sub getExistingJiraConfig {
	my $cfg;
	my $defaultValue;
	my $application   = "JIRA";
	my $mode          = "CREATE";
	my $lcApplication = lc($application);
	my $subname       = ( caller(0) )[3];
	my $serverConfigFile;
	my $serverSetEnvFile;
	my $externalCrowdInstance;
	my @parameterNull;
	my $input;
	my $LOOP = 0;
	my $returnValue;

	$log->debug("BEGIN: $subname");

	$cfg = $_[0];

	while ( $LOOP == 0 ) {

		#Ask for install dir
		genConfigItem(
			$mode,
			$cfg,
			"$lcApplication.installDir",
"Please enter the directory $application is currently installed into.",
			"",
			'(?!^.*/$)^(/.*)',
"The input you entered was not in the valid format of '/folder'. Please ensure you enter the absolute path with a "
			  . "leading '/' and NO trailing '/'.\n\n"
		);

		if ( -d escapeFilePath( $cfg->param("$lcApplication.installDir") ) ) {
			$LOOP = 1;    #break loop as directory exists
			$log->info( "$subname: Directory "
				  . escapeFilePath( $cfg->param("$lcApplication.installDir") )
				  . " exists. Proceeding..." );
			print "The directory "
			  . escapeFilePath( $cfg->param("$lcApplication.installDir") )
			  . " exists. Proceeding...\n\n";
		}
		else {
			print "The directory "
			  . escapeFilePath( $cfg->param("$lcApplication.installDir") )
			  . " does not exist. Please try again.\n\n";
			$log->info( "The directory "
				  . escapeFilePath( $cfg->param("$lcApplication.installDir") )
				  . " does not exist. Please try again." );
		}
	}

	#Ask for current installed version
	genConfigItem(
		$mode,
		$cfg,
		"$lcApplication.installedVersion",
		"Please enter the version of $application that is currently installed.",
		"",
		'^[0-9]+\.([0-9]+|[0-9]+\.[0-9]+)$',
"The input you entered was not in the valid format of 'x.x.x or x.x' (where x is a version number). Please ensure you enter the version number correctly "
		  . "\n\n"
	);

	genConfigItem(
		$mode,
		$cfg,
		"$lcApplication.javaParams",
"Enter any additional parameters currently added to the JAVA RUN_OPTS for your $application install. Just press enter if you have none.",
		"",
		"",
		""
	);

	genConfigItem(
		$mode,
		$cfg,
		"$lcApplication.catalinaOpts",
"Enter any additional currently added to the Java CATALINA_OPTS for your $application install. Just press enter if you have none.",
		"",
		"",
		""
	);

	if (   $cfg->param("general.apacheProxy") eq "TRUE"
		&& $cfg->param("general.apacheProxySingleDomain") eq "FALSE" )
	{
		genConfigItem(
			$mode,
			$cfg,
			"jira.apacheProxyHost",
"Please enter the base URL JIRA currently runs on (i.e. the proxyName such as yourdomain.com).",
			"",
			$hostnameRegex,
"The input you entered was not in the valid format of 'yourdomain.com' or 'subdomain.yourdomain.com'. Please try again.\n\n"
		);

		genBooleanConfigItem( $mode, $cfg, "jira.apacheProxySSL",
			"Do you currently run JIRA over SSL.", "no" );

		genConfigItem(
			$mode,
			$cfg,
			"jira.apacheProxyPort",
"Please enter the port number that Apache currently serves JIRA on (80 for HTTP, 443 for HTTPS in standard situations).",
			"80",
			'^([0-9]*)$',
"The input you entered was not a valid port number, please try again.\n\n"
		);
	}

	$serverSetEnvFile =
	  escapeFilePath( $cfg->param("$lcApplication.installDir") )
	  . "/bin/setenv.sh";

	$serverConfigFile =
	  escapeFilePath( $cfg->param("$lcApplication.installDir") )
	  . "/conf/server.xml";

	genBooleanConfigItem(
		$mode,
		$cfg,
		"$lcApplication.runAsService",
"Does your $application instance run as a service (i.e. runs on boot)? yes/no.",
		"yes"
	);

	print
"Please wait, attempting to get the $application data/home directory from it's config files...\n\n";
	$log->info(
"$subname: Attempting to get $application data directory from config file $serverConfigFile."
	);

	@parameterNull = $cfg->param("general.externalCrowdInstance");

	if ( $#parameterNull == -1 ) {
		$externalCrowdInstance = "FALSE";
	}
	else {
		$externalCrowdInstance = $cfg->param("general.externalCrowdInstance");
	}

	if (   $externalCrowdInstance eq "TRUE"
		|| $cfg->param("crowd.enable") eq "TRUE" )
	{
		genBooleanConfigItem(
			$mode,
			$cfg,
			"jira.crowdIntegration",
"Will you be using Crowd as the authentication backend for JIRA? yes/no.",
			"yes"
		);

		if ( $cfg->param("jira.crowdIntegration") eq "TRUE" ) {
			genBooleanConfigItem( $mode, $cfg, "jira.crowdSSO",
				"Will you be using Crowd for Single Sign On (SSO)? yes/no.",
				"yes" );
		}
	}
	else {
		$cfg->param( "jira.crowdIntegration", "FALSE" );
		$cfg->param( "jira.crowdSSO",         "FALSE" );
	}

	#get data/home directory
	$returnValue = getLineFromFile(
		escapeFilePath( $cfg->param("$lcApplication.installDir") )
		  . "/atlassian-jira/WEB-INF/classes/jira-application.properties",
		"jira.home\\s?=", ".*=\\s?(.*)"
	);

	if ( $returnValue eq "NOTFOUND" ) {
		$log->info(
"$subname: Unable to locate $application data directory. Asking user for input."
		);
		genConfigItem(
			$mode,
			$cfg,
			"$lcApplication.dataDir",
"Unable to find the data directory in the expected location in the $application config. Please enter the directory $application"
			  . "'s data is *currently* stored in.",
			"",
			'(?!^.*/$)^(/.*)',
"The input you entered was not in the valid format of '/folder'. Please ensure you enter the absolute path with a "
			  . "leading '/' and NO trailing '/'.\n\n"
		);
	}
	else {
		$cfg->param( "$lcApplication.dataDir", $returnValue );
		print
"$application data directory has been found successfully and added to the config file...\n\n";
		$log->info(
			"$subname: $application data directory found and added to config."
		);
	}

	#getContextFromFile
	$returnValue = "";

	print
"Please wait, attempting to get the $application context from it's config files...\n\n";
	$log->info(
"$subname: Attempting to get $application context from config file $serverConfigFile."
	);
	$returnValue =
	  getXMLAttribute( $serverConfigFile, "//////Context", "path" );

	if ( $returnValue eq "NOTFOUND" ) {
		$log->info(
"$subname: Unable to locate $application context. Asking user for input."
		);
		genConfigItem(
			$mode,
			$cfg,
			"$lcApplication.appContext",
"Unable to find the context in the expected location in the $application config. Please enter the context that $application currently runs under (i.e. /confluence or /wiki). Write NULL to blank out the context.",
			"/confluence",
			'(?!^.*/$)^(/.*)',
"The input you entered was not in the valid format of '/folder'. Please ensure you enter the path with a "
			  . "leading '/' and NO trailing '/'.\n\n"
		);
	}
	else {
		if ( $returnValue eq "" ) {
			$returnValue = "NULL";
		}
		$cfg->param( "$lcApplication.appContext", $returnValue );
		print
"$application context has been found successfully and added to the config file...\n\n";
		$log->info("$subname: $application context found and added to config.");
	}

	$returnValue = "";

	print
"Please wait, attempting to get the $application connectorPort from it's config files...\n\n";
	$log->info(
"$subname: Attempting to get $application connectorPort from config file $serverConfigFile."
	);

	#Get connector port from file
	$returnValue = getXMLAttribute( $serverConfigFile, "///Connector", "port" );

	if ( $returnValue eq "NOTFOUND" ) {
		$log->info(
"$subname: Unable to locate $application connectorPort. Asking user for input."
		);
		genConfigItem(
			$mode,
			$cfg,
			"$lcApplication.connectorPort",
"Unable to find the connector port in the expected location in the $application config. Please enter the Connector port $application *currently* runs on (note this is the port you will access in the browser).",
			"8080",
			'^([0-9]*)$',
"The port number you entered contained invalid characters. Please ensure you enter only digits.\n\n"
		);
	}
	else {
		$cfg->param( "$lcApplication.connectorPort", $returnValue );
		print
"$application connectorPort has been found successfully and added to the config file...\n\n";
		$log->info(
			"$subname: $application connectorPort found and added to config.");
	}

	$returnValue = "";

	print
"Please wait, attempting to get the $application serverPort from it's config files...\n\n";
	$log->info(
"$subname: Attempting to get $application serverPort from config file $serverConfigFile."
	);

	#Get connector port from file
	$returnValue = getXMLAttribute( $serverConfigFile, "/Server", "port" );

	if ( $returnValue eq "NOTFOUND" ) {
		$log->info(
"$subname: Unable to locate $application serverPort. Asking user for input."
		);
		genConfigItem(
			$mode,
			$cfg,
			"$lcApplication.serverPort",
"Unable to find the server port in the expected location in the $application config. Please enter the Server port $application *currently* runs on (note this is the tomcat control port).",
			"8003",
			'^([0-9]*)$',
"The port number you entered contained invalid characters. Please ensure you enter only digits.\n\n"
		);
	}
	else {
		$cfg->param( "$lcApplication.serverPort", $returnValue );
		print
"$application serverPort has been found successfully and added to the config file...\n\n";
		$log->info(
			"$subname: $application serverPort found and added to config.");
	}

	$returnValue = "";

	print
"Please wait, attempting to get the $application Xms java memory parameter from it's config files...\n\n";
	$log->info(
"$subname: Attempting to get $application Xms java memory parameter from config file $serverConfigFile."
	);
	$returnValue = getLineFromFile( $serverSetEnvFile, "JVM_MINIMUM_MEMORY",
		".*\\s?=\\s?(.*)" );
	if ( $returnValue eq "NOTFOUND" ) {
		$log->info(
"$subname: Unable to locate $application Xms memory parameter. Asking user for input."
		);
		genConfigItem(
			$mode,
			$cfg,
			"$lcApplication.javaMinMemory",
"Unable to find the java Xms memory parameter in the expected location in the $application config. Please enter the minimum amount of memory *currently* assigned to $application.",
			"256m",
			'^([0-9]*m)$',
"The memory value you entered is in an invalid format. Please ensure you use the format '1234m'. (i.e. '256m')"
		);
	}
	else {
		$cfg->param( "$lcApplication.javaMinMemory", $returnValue );
		print
"$application Xms java memory parameter has been found successfully and added to the config file...\n\n";
		$log->info(
"$subname: $application Xms java memory parameter found and added to config."
		);
	}

	$returnValue = "";

	print
"Please wait, attempting to get the $application Xmx java memory parameter from it's config files...\n\n";
	$log->info(
"$subname: Attempting to get $application Xmx java memory parameter from config file $serverConfigFile."
	);
	$returnValue = getLineFromFile( $serverSetEnvFile, "JVM_MAXIMUM_MEMORY",
		".*\\s?=\\s?(.*)" );
	if ( $returnValue eq "NOTFOUND" ) {
		$log->info(
"$subname: Unable to locate $application Xmx memory parameter. Asking user for input."
		);
		genConfigItem(
			$mode,
			$cfg,
			"$lcApplication.javaMaxMemory",
"Unable to find the java Xmx memory parameter in the expected location in the $application config. Please enter the maximum amount of memory *currently* assigned to $application.",
			"512m",
			'^([0-9]*m)$',
"The memory value you entered is in an invalid format. Please ensure you use the format '1234m'. (i.e. '256m')"
		);
	}
	else {
		$cfg->param( "$lcApplication.javaMaxMemory", $returnValue );
		print
"$application Xmx java memory parameter has been found successfully and added to the config file...\n\n";
		$log->info(
"$subname: $application Xmx java memory parameter found and added to config."
		);
	}

	$returnValue = "";

	print
"Please wait, attempting to get the $application XX:MaxPermSize java memory parameter from it's config files...\n\n";
	$log->info(
"$subname: Attempting to get $application XX:MaxPermSize java memory parameter from config file $serverConfigFile."
	);
	$returnValue = getLineFromFile( $serverSetEnvFile, "JIRA_MAX_PERM_SIZE",
		".*\\s?=\\s?(.*)" );
	if ( $returnValue eq "NOTFOUND" ) {
		$log->info(
"$subname: Unable to locate $application XX:MaxPermSize memory parameter. Asking user for input."
		);
		genConfigItem(
			$mode,
			$cfg,
			"$lcApplication.javaMaxPermSize",
"Unable to find the java XX:MaxPermSize memory parameter in the expected location in the $application config. Please enter the maximum amount of permGen memory *currently* assigned to $application.",
			"256m",
			'^([0-9]*m)$',
"The memory value you entered is in an invalid format. Please ensure you use the format '1234m'. (i.e. '256m')"
		);
	}
	else {
		$cfg->param( "$lcApplication.javaMaxPermSize", $returnValue );
		print
"$application XX:MaxPermSize java memory parameter has been found successfully and added to the config file...\n\n";
		$log->info(
"$subname: $application XX:MaxPermSize java memory parameter found and added to config."
		);
	}

	$returnValue = "";

	#getOSuser
	open( my $inputFileHandle,
		'<', escapeFilePath( $cfg->param("$lcApplication.installDir") ) )
	  or $log->logdie(
"Unable to open install dir for $application to test who owns it. Really this should never happen as we have already tested that the directory exists."
	  );
	my (
		$dev,   $ino,     $fileMode, $nlink, $uid,
		$gid,   $rdev,    $size,     $atime, $mtime,
		$ctime, $blksize, $blocks
	) = stat($inputFileHandle);
	$returnValue = getpwuid($uid);

	close $inputFileHandle;

	#confirmWithUserThatIsTheCorrectOSUser
	$input = getBooleanInput(
"We have detected that the user $application runs under is '$returnValue'. Is this correct? yes/no [yes]: "
	);
	print "\n";
	if ( $input eq "default" || $input eq "yes" ) {
		$cfg->param( "$lcApplication.osUser", $returnValue );
		print
		  "The osUser $returnValue has been added to the config file...\n\n";
		$log->info(
"$subname: User confirmed that the user $application runs under is $returnValue. This has been added to the config."
		);
	}
	else {
		genConfigItem(
			$mode,
			$cfg,
			"$lcApplication.osUser",
"In that case please enter the user that $application *currently* runs under.",
			"",
			'^([a-zA-Z0-9]*)$',
"The user you entered was in an invalid format. Please ensure you enter only letters and numbers without any spaces or other characters.\n\n"
		);
	}

	if (   $cfg->param("general.apacheProxy") eq "TRUE"
		&& $cfg->param("general.apacheProxySingleDomain") eq "FALSE" )
	{
		$returnValue = "";

		print
"Please wait, attempting to get the Apache proxy base hostname configuration for $application from the configuration files...\n\n";
		$log->info(
"$subname: Attempting to get $application proxyName from config file $serverConfigFile."
		);
		$returnValue =
		  getXMLAttribute( $serverConfigFile, "///Connector", "proxyName" );

		if ( $returnValue eq "NOTFOUND" ) {
			$log->info(
"$subname: Unable to locate $application proxyName. Asking user for input."
			);
			genConfigItem(
				$mode,
				$cfg,
				"$lcApplication.apacheProxyHost",
"Unable to find the base hostname attribute in the expected location in the $application config. Please enter the base URL that will be serving the site (i.e. the proxyName such as yourdomain.com).",
				"",
				$hostnameRegex,
"The input you entered was not in the valid format of 'yourdomain.com' or 'subdomain.yourdomain.com'. Please try again.\n\n"
			);
		}
		else {
			$cfg->param( "$lcApplication.apacheProxyHost", $returnValue );
			print
"$application base hostname has been found successfully and added to the config file...\n\n";
			$log->info(
"$subname: $application base hostname found and added to config."
			);
		}

		$returnValue = "";

		print
"Please wait, attempting to get the Apache proxy scheme configuration for $application from the configuration files...\n\n";
		$log->info(
"$subname: Attempting to get $application proxy scheme from config file $serverConfigFile."
		);
		$returnValue =
		  getXMLAttribute( $serverConfigFile, "///Connector", "scheme" );

		if ( $returnValue eq "NOTFOUND" ) {
			$log->info(
"$subname: Unable to locate $application proxy scheme. Asking user for input."
			);
			genBooleanConfigItem(
				$mode,
				$cfg,
				"$lcApplication.apacheProxySSL",
"Unable to locate the Apache proxy scheme configuration in $application config. Will you be running $application over SSL.",
				"no"
			);
		}
		else {
			if ( $returnValue eq "http" ) {
				$log->info(
"$subname: return value for Apache Proxy Scheme config is 'http'."
				);
				$cfg->param( "$lcApplication.apacheProxySSL", "FALSE" );
			}
			elsif ( $returnValue eq "https" ) {
				$log->info(
"$subname: return value for Apache Proxy Scheme config is 'http'."
				);
				$cfg->param( "$lcApplication.apacheProxySSL", "TRUE" );
			}
			else {
				$log->info(
"$subname: return value for Apache Proxy Scheme config is 'UNKNOWN' This is not good."
				);
				$cfg->param( "$lcApplication.apacheProxySSL", "UNKNOWN" );
			}
			print
"$application Apache Proxy scheme has been found successfully and added to the config file...\n\n";
			$log->info(
				"$subname: $application proxy scheme found and added to config."
			);
		}

		$returnValue = "";

		print
"Please wait, attempting to get the Apache proxy port configuration for $application from the configuration files...\n\n";
		$log->info(
"$subname: Attempting to get $application proxyPort from config file $serverConfigFile."
		);
		$returnValue =
		  getXMLAttribute( $serverConfigFile, "///Connector", "proxyPort" );

		if ( $returnValue eq "NOTFOUND" ) {
			$log->info(
"$subname: Unable to locate $application proxyPort. Asking user for input."
			);
			genConfigItem(
				$mode,
				$cfg,
				"$lcApplication.apacheProxyPort",
"Unable to find the Apache proxy port attribute in the expected location in the $application config. Please enter the port number that Apache currently serves on (80 for HTTP, 443 for HTTPS in standard situations).",
				"80/443",
				'^([0-9]*)$',
"The input you entered was not a valid port number, please try again.\n\n"
			);
		}
		else {
			$cfg->param( "$lcApplication.apacheProxyPort", $returnValue );
			print
"$application base hostname has been found successfully and added to the config file...\n\n";
			$log->info(
"$subname: $application base hostname found and added to config."
			);
		}
	}

	#Set up some defaults for JIRA
	$cfg->param( "$lcApplication.processSearchParameter1", "java" );
	$cfg->param( "$lcApplication.processSearchParameter2",
		"classpath " . $cfg->param("$lcApplication.installDir") );
	$cfg->param( "$lcApplication.enable", "TRUE" );

	$cfg->write($configFile);
	loadSuiteConfig();

	print
"We now have the $application config and it has been written to the config file. Please press enter to continue.\n";
	$input = <STDIN>;
}

########################################
#GenerateJiraConfig                    #
########################################
sub generateJiraConfig {
	my $cfg;
	my $mode;
	my $defaultValue;
	my $externalCrowdInstance;
	my @parameterNull;
	my $application = "JIRA";
	my $subname     = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");
	$mode = $_[0];
	$cfg  = $_[1];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_mode", $mode );

	genConfigItem(
		$mode,
		$cfg,
		"jira.installDir",
		"Please enter the directory Jira will be installed into.",
		$cfg->param("general.rootInstallDir") . "/jira",
		'(?!^.*/$)^(/.*)',
"The input you entered was not in the valid format of '/folder'. Please ensure you enter the absolute path with a "
		  . "leading '/' and NO trailing '/'.\n\n"
	);

	genConfigItem(
		$mode,
		$cfg,
		"jira.dataDir",
		"Please enter the directory Jira's data will be stored in.",
		$cfg->param("general.rootDataDir") . "/jira",
		'(?!^.*/$)^(/.*)',
"The input you entered was not in the valid format of '/folder'. Please ensure you enter the absolute path with a "
		  . "leading '/' and NO trailing '/'.\n\n"
	);

	genConfigItem(
		$mode,
		$cfg,
		"jira.osUser",
		"Enter the user that JIRA will run under.",
		"jira",
		'^([a-zA-Z0-9]*)$',
"The user you entered was in an invalid format. Please ensure you enter only letters and numbers without any spaces or other characters.\n\n"
	);

	genConfigItem(
		$mode,
		$cfg,
		"jira.appContext",
"Enter the context that Jira should run under (i.e. /jira or /bugtraq). Write NULL to blank out the context.",
		"/jira",
		'(?!^.*/$)^(/.*)',
"The input you entered was not in the valid format of '/folder'. Please ensure you enter the path with a "
		  . "leading '/' and NO trailing '/'.\n\n"
	);

	genConfigItem(
		$mode,
		$cfg,
		"jira.connectorPort",
"Please enter the Connector port Jira will run on (note this is the port you will access in the browser).",
		"8080",
		'^([0-9]*)$',
"The port number you entered contained invalid characters. Please ensure you enter only digits.\n\n"
	);

	checkConfiguredPort( $application, "jira.connectorPort", $cfg );

	genConfigItem(
		$mode,
		$cfg,
		"jira.serverPort",
"Please enter the SERVER port Jira will run on (note this is the control port not the port you access in a browser).",
		"8003",
		'^([0-9]*)$',
"The port number you entered contained invalid characters. Please ensure you enter only digits.\n\n"
	);

	checkConfiguredPort( $application, "jira.serverPort", $cfg );

	genConfigItem(
		$mode,
		$cfg,
		"jira.javaParams",
"Enter any additional parameters you would like to add to the Java RUN_OPTS.",
		"",
		"",
		""
	);

	genConfigItem(
		$mode,
		$cfg,
		"jira.catalinaOpts",
"Enter any additional parameters you would like to add to the Java CATALINA_OPTS.",
		"",
		"",
		""
	);

	genConfigItem(
		$mode,
		$cfg,
		"jira.javaMinMemory",
		"Enter the minimum amount of memory you would like to assign to Jira.",
		"256m",
		'^([0-9]*m)$',
"The memory value you entered is in an invalid format. Please ensure you use the format '1234m'. (i.e. '256m')"
	);

	genConfigItem(
		$mode,
		$cfg,
		"jira.javaMaxMemory",
		"Enter the maximum amount of memory you would like to assign to Jira.",
		"768m",
		'^([0-9]*m)$',
"The memory value you entered is in an invalid format. Please ensure you use the format '1234m'. (i.e. '256m')"
	);

	genConfigItem(
		$mode,
		$cfg,
		"jira.javaMaxPermSize",
"Enter the amount of memory for the MAX_PERM_SIZE parameter that you would like to assign to Jira.",
		"256m",
		'^([0-9]*m)$',
"The memory value you entered is in an invalid format. Please ensure you use the format '1234m'. (i.e. '256m')"
	);

	if (   $cfg->param("general.apacheProxy") eq "TRUE"
		&& $cfg->param("general.apacheProxySingleDomain") eq "FALSE" )
	{
		genConfigItem(
			$mode,
			$cfg,
			"jira.apacheProxyHost",
"Please enter the base URL that will be serving the site (i.e. the proxyName such as yourdomain.com).",
			"",
			$hostnameRegex,
"The input you entered was not in the valid format of 'yourdomain.com' or 'subdomain.yourdomain.com'. Please try again.\n\n"
		);

		genBooleanConfigItem( $mode, $cfg, "jira.apacheProxySSL",
			"Will you be running JIRA over SSL.", "no" );

		genConfigItem(
			$mode,
			$cfg,
			"jira.apacheProxyPort",
"Please enter the port number that Apache will serve on (80 for HTTP, 443 for HTTPS in standard situations).",
			"80",
			'^([0-9]*)$',
"The input you entered was not a valid port number, please try again.\n\n"
		);
	}

	@parameterNull = $cfg->param("general.externalCrowdInstance");

	if ( $#parameterNull == -1 ) {
		$externalCrowdInstance = "FALSE";
	}
	else {
		$externalCrowdInstance = $cfg->param("general.externalCrowdInstance");
	}

	if (   $externalCrowdInstance eq "TRUE"
		|| $cfg->param("crowd.enable") eq "TRUE" )
	{
		genBooleanConfigItem(
			$mode,
			$cfg,
			"jira.crowdIntegration",
"Will you be using Crowd as the authentication backend for JIRA? yes/no.",
			"yes"
		);

		if ( $cfg->param("jira.crowdIntegration") eq "TRUE" ) {
			genBooleanConfigItem( $mode, $cfg, "jira.crowdSSO",
				"Will you be using Crowd for Single Sign On (SSO)? yes/no.",
				"yes" );
		}
	}
	else {
		$cfg->param( "jira.crowdIntegration", "FALSE" );
		$cfg->param( "jira.crowdSSO",         "FALSE" );
	}

	genBooleanConfigItem( $mode, $cfg, "jira.runAsService",
		"Would you like to run Jira as a service? yes/no.", "yes" );

	#Set up some defaults for JIRA
	$cfg->param( "jira.processSearchParameter1", "java" );
	$cfg->param( "jira.processSearchParameter2",
		"classpath " . $cfg->param("jira.installDir") );

	$cfg->param( "jira.enable", "TRUE" );
}

########################################
#Install Jira                          #
########################################
sub installJira {
	my $serverXMLFile;
	my $initPropertiesFile;
	my @parameterNull;
	my $javaOptsValue;
	my $catalinaOptsValue;
	my $application   = "JIRA";
	my $lcApplication = lc($application);
	my $javaMemParameterFile;
	my $osUser;
	my $downloadArchivesUrl =
	  "http://www.atlassian.com/software/jira/download-archives";
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	#Set up list of config items that are requred for this install to run
	my @requiredConfigItems;
	@requiredConfigItems = (
		"jira.appContext",              "jira.enable",
		"jira.dataDir",                 "jira.installDir",
		"jira.runAsService",            "jira.serverPort",
		"jira.connectorPort",           "jira.javaMinMemory",
		"jira.javaMaxMemory",           "jira.javaMaxPermSize",
		"jira.processSearchParameter1", "jira.processSearchParameter2",
		"jira.crowdIntegration",        "jira.osUser"
	);

	if ( $globalConfig->param("general.apacheProxy") eq "TRUE" ) {
		if (
			$globalConfig->param("general.apacheProxySingleDomain") eq "FALSE" )
		{
			push( @requiredConfigItems, "jira.apacheProxyPort" );
			push( @requiredConfigItems, "jira.apacheProxySSL" );
			push( @requiredConfigItems, "jira.apacheProxyHost" );
		}
	}

	#Run generic installer steps
	installGeneric( $application, $downloadArchivesUrl, \@requiredConfigItems );
	$osUser = $globalConfig->param("$lcApplication.osUser")
	  ; #we get this after install in CASE the installer changes the configured user in future

	#Force update config items for search parameters
	$globalConfig->param( "jira.processSearchParameter1", "java" );
	$globalConfig->param( "jira.processSearchParameter2",
		"classpath " . $globalConfig->param("$lcApplication.installDir") );
	$globalConfig->write($configFile);
	loadSuiteConfig();

	#Perform application specific configuration
	print "Applying configuration settings to the install, please wait...\n\n";

	$serverXMLFile =
	  escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
	  . "/conf/server.xml";

	$initPropertiesFile =
	  escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
	  . "/atlassian-jira/WEB-INF/classes/$lcApplication-application.properties";
	$javaMemParameterFile =
	  escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
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

	#Update the server config with reverse proxy configuration
	$log->info( "$subname: Updating the reverse proxy configuration in "
		  . $serverXMLFile );
	print "Applying Apache proxy parameters to config...\n\n";
	if ( $globalConfig->param("general.apacheProxy") eq "TRUE" ) {
		if ( $globalConfig->param("general.apacheProxySingleDomain") eq "TRUE" )
		{
			updateXMLAttribute( $serverXMLFile, "///Connector", "proxyName",
				$globalConfig->param("general.apacheProxyHost") );

			if ( $globalConfig->param("general.apacheProxySSL") eq "TRUE" ) {
				updateXMLAttribute( $serverXMLFile, "///Connector", "scheme",
					"https" );
			}
			else {
				updateXMLAttribute( $serverXMLFile, "///Connector", "scheme",
					"http" );
			}
			updateXMLAttribute( $serverXMLFile, "///Connector", "secure",
				"false" );
			updateXMLAttribute( $serverXMLFile, "///Connector", "proxyPort",
				$globalConfig->param("general.apacheProxyPort") );
		}
		else {
			updateXMLAttribute( $serverXMLFile, "///Connector", "proxyName",
				$globalConfig->param("$lcApplication.apacheProxyHost") );
			if ( $globalConfig->param("$lcApplication.apacheProxySSL") eq
				"TRUE" )
			{
				updateXMLAttribute( $serverXMLFile, "///Connector", "scheme",
					"https" );
			}
			else {
				updateXMLAttribute( $serverXMLFile, "///Connector", "scheme",
					"http" );
			}
			updateXMLAttribute( $serverXMLFile, "///Connector", "secure",
				"false" );
			updateXMLAttribute( $serverXMLFile, "///Connector", "proxyPort",
				$globalConfig->param("$lcApplication.apacheProxyPort") );
		}
	}

	#Edit JIRA config file to reference homedir
	$log->info( "$subname: Applying homedir in " . $initPropertiesFile );
	print "Applying home directory to config...\n\n";
	updateLineInFile(
		$initPropertiesFile,
		"jira.home =",
		"jira.home ="
		  . escapeFilePath( $globalConfig->param("$lcApplication.dataDir") ),
		"# jira.home ="
	);

	@parameterNull = $globalConfig->param("$lcApplication.javaParams");
	if (   ( $#parameterNull == -1 )
		|| $globalConfig->param("$lcApplication.javaParams") eq ""
		|| $globalConfig->param("$lcApplication.javaParams") eq "default" )
	{
		$javaOptsValue = "NOJAVAOPTSCONFIGSPECIFIED";
	}
	else {
		$javaOptsValue = "CONFIGSPECIFIED";
	}

	#Apply the JavaOpts configuration (if any)
	print "Applying Java_Opts configuration to install...\n\n";
	if ( $javaOptsValue ne "NOJAVAOPTSCONFIGSPECIFIED" ) {
		updateJavaOpts(
			escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
			  . "/bin/setenv.sh",
			"JAVA_OPTS",
			getConfigItem( "$lcApplication.javaParams", $globalConfig )
		);
	}

	#Apply Catalina Opts to Install
	@parameterNull = $globalConfig->param("$lcApplication.catalinaOpts");
	if (   ( $#parameterNull == -1 )
		|| $globalConfig->param("$lcApplication.catalinaOpts") eq ""
		|| $globalConfig->param("$lcApplication.catalinaOpts") eq "default" )
	{
		$catalinaOptsValue = "NOCATALINAOPTSCONFIGSPECIFIED";
	}
	else {
		$catalinaOptsValue = "CONFIGSPECIFIED";
	}

	print "Applying CATALINA_OPTS configuration to install...\n\n";
	if ( $javaOptsValue ne "NOCATALINAOPTSCONFIGSPECIFIED" ) {
		updateCatalinaOpts(
			$application,
			escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
			  . "/bin/setenv.sh",
			"CATALINA_OPTS=",
			getConfigItem( "$lcApplication.catalinaOpts", $globalConfig )
		);
	}

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
		"JIRA_MAX_PERM_SIZE",
		"JIRA_MAX_PERM_SIZE="
		  . $globalConfig->param("$lcApplication.javaMaxPermSize"),
		"#JIRA_MAX_PERM_SIZE="
	);

	#Generate the init.d file
	print
"Setting up initd files and run as a service (if configured) please wait...\n\n";
	$log->info("$subname: Generating init.d file for $application.");

	generateInitD(
		$application,
		$osUser,
		escapeFilePath( $globalConfig->param("$lcApplication.installDir") ),
		"/bin/start-jira.sh",
		"/bin/stop-jira.sh",
		$globalConfig->param("$lcApplication.processSearchParameter1"),
		$globalConfig->param("$lcApplication.processSearchParameter2")
	);

	#Finally run generic post install tasks
	postInstallGeneric($application);
}

########################################
#Uninstall Jira                        #
########################################
sub uninstallJira {
	my $application = "JIRA";
	my $subname     = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");
	uninstallGeneric($application);
}

########################################
#UpgradeJira                          #
########################################
sub upgradeJira {
	my $serverXMLFile;
	my $initPropertiesFile;
	my @parameterNull;
	my $javaOptsValue;
	my $catalinaOptsValue;
	my $application   = "JIRA";
	my $lcApplication = lc($application);
	my $javaMemParameterFile;
	my $osUser;
	my $downloadArchivesUrl =
	  "http://www.atlassian.com/software/jira/download-archives";
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	#Set up list of config items that are requred for this install to run
	my @requiredConfigItems;
	@requiredConfigItems = (
		"jira.appContext",              "jira.enable",
		"jira.dataDir",                 "jira.installDir",
		"jira.runAsService",            "jira.serverPort",
		"jira.connectorPort",           "jira.javaMinMemory",
		"jira.javaMaxMemory",           "jira.javaMaxPermSize",
		"jira.processSearchParameter1", "jira.processSearchParameter2",
		"jira.crowdIntegration",        "jira.osUser"
	);

	if ( $globalConfig->param("general.apacheProxy") eq "TRUE" ) {
		if (
			$globalConfig->param("general.apacheProxySingleDomain") eq "FALSE" )
		{
			push( @requiredConfigItems, "jira.apacheProxyPort" );
			push( @requiredConfigItems, "jira.apacheProxySSL" );
			push( @requiredConfigItems, "jira.apacheProxyHost" );
		}
	}

	#Back up the Crowd configuration files
	if ( $globalConfig->param("$lcApplication.crowdIntegration") eq "TRUE" ) {
		$log->info("$subname: Backing up Crowd configuration files.");
		print "Backing up the Crowd configuration files...\n\n";
		if ( -e $globalConfig->param("$lcApplication.installDir")
			. "/atlassian-jira/WEB-INF/classes/crowd.properties" )
		{
			copyFile(
				$globalConfig->param("$lcApplication.installDir")
				  . "/atlassian-jira/WEB-INF/classes/crowd.properties",
				"$Bin/working/crowd.properties.$lcApplication"
			);
		}
		else {
			print
"No crowd.properties currently exists for $application, will not copy.\n\n";
			$log->info(
"$subname: No crowd.properties currently exists for $application, will not copy."
			);
		}
	}

	#Force update config items for search parameters
	$globalConfig->param( "jira.processSearchParameter1", "java" );
	$globalConfig->param( "jira.processSearchParameter2",
		"classpath " . $globalConfig->param("$lcApplication.installDir") );
	$globalConfig->write($configFile);
	loadSuiteConfig();

	#Run generic installer steps
	upgradeGeneric( $application, $downloadArchivesUrl, \@requiredConfigItems );
	$osUser = $globalConfig->param("$lcApplication.osUser")
	  ; #we get this after install in CASE the installer changes the configured user in future

	#Perform application specific configuration
	print "Applying configuration settings to the install, please wait...\n\n";

	$serverXMLFile =
	  escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
	  . "/conf/server.xml";

	$initPropertiesFile =
	  escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
	  . "/atlassian-jira/WEB-INF/classes/$lcApplication-application.properties";
	$javaMemParameterFile =
	  escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
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

	#Update the server config with reverse proxy configuration
	$log->info( "$subname: Updating the reverse proxy configuration in "
		  . $serverXMLFile );
	print "Applying Apache proxy parameters to config...\n\n";
	if ( $globalConfig->param("general.apacheProxy") eq "TRUE" ) {
		if ( $globalConfig->param("general.apacheProxySingleDomain") eq "TRUE" )
		{
			updateXMLAttribute( $serverXMLFile, "///Connector", "proxyName",
				$globalConfig->param("general.apacheProxyHost") );

			if ( $globalConfig->param("general.apacheProxySSL") eq "TRUE" ) {
				updateXMLAttribute( $serverXMLFile, "///Connector", "scheme",
					"https" );
			}
			else {
				updateXMLAttribute( $serverXMLFile, "///Connector", "scheme",
					"http" );
			}
			updateXMLAttribute( $serverXMLFile, "///Connector", "secure",
				"false" );
			updateXMLAttribute( $serverXMLFile, "///Connector", "proxyPort",
				$globalConfig->param("general.apacheProxyPort") );
		}
		else {
			updateXMLAttribute( $serverXMLFile, "///Connector", "proxyName",
				$globalConfig->param("$lcApplication.apacheProxyHost") );
			if ( $globalConfig->param("$lcApplication.apacheProxySSL") eq
				"TRUE" )
			{
				updateXMLAttribute( $serverXMLFile, "///Connector", "scheme",
					"https" );
			}
			else {
				updateXMLAttribute( $serverXMLFile, "///Connector", "scheme",
					"http" );
			}
			updateXMLAttribute( $serverXMLFile, "///Connector", "secure",
				"false" );
			updateXMLAttribute( $serverXMLFile, "///Connector", "proxyPort",
				$globalConfig->param("$lcApplication.apacheProxyPort") );
		}
	}

	#Edit JIRA config file to reference homedir
	$log->info( "$subname: Applying homedir in " . $initPropertiesFile );
	print "Applying home directory to config...\n\n";
	updateLineInFile(
		$initPropertiesFile,
		"jira.home =",
		"jira.home ="
		  . escapeFilePath( $globalConfig->param("$lcApplication.dataDir") ),
		"# jira.home ="
	);

	@parameterNull = $globalConfig->param("$lcApplication.javaParams");
	if (   ( $#parameterNull == -1 )
		|| $globalConfig->param("$lcApplication.javaParams") eq ""
		|| $globalConfig->param("$lcApplication.javaParams") eq "default" )
	{
		$javaOptsValue = "NOJAVAOPTSCONFIGSPECIFIED";
	}
	else {
		$javaOptsValue = "CONFIGSPECIFIED";
	}

	#Apply the JavaOpts configuration (if any)
	print "Applying Java_Opts configuration to install...\n\n";
	if ( $javaOptsValue ne "NOJAVAOPTSCONFIGSPECIFIED" ) {
		updateJavaOpts(
			escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
			  . "/bin/setenv.sh",
			"JAVA_OPTS",
			getConfigItem( "$lcApplication.javaParams", $globalConfig )
		);
	}

	#Apply Catalina Opts to Install
	@parameterNull = $globalConfig->param("$lcApplication.catalinaOpts");
	if (   ( $#parameterNull == -1 )
		|| $globalConfig->param("$lcApplication.catalinaOpts") eq ""
		|| $globalConfig->param("$lcApplication.catalinaOpts") eq "default" )
	{
		$catalinaOptsValue = "NOCATALINAOPTSCONFIGSPECIFIED";
	}
	else {
		$catalinaOptsValue = "CONFIGSPECIFIED";
	}

	print "Applying CATALINA_OPTS configuration to install...\n\n";
	if ( $javaOptsValue ne "NOCATALINAOPTSCONFIGSPECIFIED" ) {
		updateCatalinaOpts(
			$application,
			escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
			  . "/bin/setenv.sh",
			"CATALINA_OPTS=",
			getConfigItem( "$lcApplication.catalinaOpts", $globalConfig )
		);
	}

	#Restore the Crowd configuration files
	if ( $globalConfig->param("$lcApplication.crowdIntegration") eq "TRUE" ) {
		$log->info("$subname: Restoring Crowd configuration files.");
		print "Restoring the Crowd configuration files...\n\n";
		if (
			-e escapeFilePath(
				$globalConfig->param("$lcApplication.installDir")
				  . "/atlassian-jira/WEB-INF/classes/crowd.properties"
			)
		  )
		{
			backupFile(
				escapeFilePath(
					$globalConfig->param("$lcApplication.installDir")
					  . "/atlassian-jira/WEB-INF/classes/crowd.properties"
				),
				$osUser
			);
		}
		if ( -e escapeFilePath("$Bin/working/crowd.properties.$lcApplication") )
		{
			copyFile(
				escapeFilePath("$Bin/working/crowd.properties.$lcApplication"),
				escapeFilePath(
					$globalConfig->param("$lcApplication.installDir")
					  . "/atlassian-jira/WEB-INF/classes/crowd.properties"
				)
			);

			chownFile(
				$osUser,
				escapeFilePath(
					$globalConfig->param("$lcApplication.installDir")
					  . "/atlassian-jira/WEB-INF/classes/crowd.properties"
				)
			);
		}
		else {
			print
"No crowd.properties currently exists for $application that has been backed up, will not restore.\n\n";
			$log->info(
"$subname: No crowd.properties currently exists for $application that has been backed up, will not restore."
			);
		}
	}

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
		"JIRA_MAX_PERM_SIZE",
		"JIRA_MAX_PERM_SIZE="
		  . $globalConfig->param("$lcApplication.javaMaxPermSize"),
		"#JIRA_MAX_PERM_SIZE="
	);

	#Apply Seraph Config
	if ( $globalConfig->param("$lcApplication.crowdSSO") eq "TRUE" ) {
		backupFile(
			escapeFilePath(
				$globalConfig->param("$lcApplication.installDir")
				  . "/atlassian-jira/WEB-INF/classes/seraph-config.xml"
			),
			$osUser
		);
		updateSeraphConfig(
			$application,
			escapeFilePath(
				$globalConfig->param("$lcApplication.installDir")
				  . "/atlassian-jira/WEB-INF/classes/seraph-config.xml"
			),
			"com.atlassian.jira.security.login.SSOSeraphAuthenticator",
			"com.atlassian.jira.security.login.JiraSeraphAuthenticator"
		);
	}

	#Generate the init.d file
	print
"Setting up initd files and run as a service (if configured) please wait...\n\n";
	$log->info("$subname: Generating init.d file for $application.");

	generateInitD(
		$application,
		$osUser,
		escapeFilePath( $globalConfig->param("$lcApplication.installDir") ),
		"/bin/start-jira.sh",
		"/bin/stop-jira.sh",
		$globalConfig->param("$lcApplication.processSearchParameter1"),
		$globalConfig->param("$lcApplication.processSearchParameter2")
	);

	#clear the JIRA plugin cache for good measure (see [#ATLASMGR-341])
	clearJIRAPluginCache();

	#Finally run generic post install tasks
	postUpgradeGeneric($application);
}

#######################################################################
#END JIRA MANAGER FUNCTIONS                                           #
#######################################################################

#######################################################################
#BEGIN STASH MANAGER FUNCTIONS                                        #
#######################################################################

########################################
#getExistingStashConfig                #
########################################
sub getExistingStashConfig {
	my $cfg;
	my $defaultValue;
	my $application   = "Stash";
	my $mode          = "CREATE";
	my $lcApplication = lc($application);
	my $subname       = ( caller(0) )[3];
	my $serverConfigFile;
	my $serverSetEnvFile;
	my $externalCrowdInstance;
	my @parameterNull;
	my $input;
	my $LOOP = 0;
	my $returnValue;

	$log->debug("BEGIN: $subname");

	$cfg = $_[0];

	while ( $LOOP == 0 ) {

		#Ask for install dir
		genConfigItem(
			$mode,
			$cfg,
			"$lcApplication.installDir",
"Please enter the directory $application is currently installed into.",
			"",
			'(?!^.*/$)^(/.*)',
"The input you entered was not in the valid format of '/folder'. Please ensure you enter the absolute path with a "
			  . "leading '/' and NO trailing '/'.\n\n"
		);

		if ( -d escapeFilePath( $cfg->param("$lcApplication.installDir") ) ) {
			$LOOP = 1;    #break loop as directory exists
			$log->info( "$subname: Directory "
				  . escapeFilePath( $cfg->param("$lcApplication.installDir") )
				  . " exists. Proceeding..." );
			print "The directory "
			  . escapeFilePath( $cfg->param("$lcApplication.installDir") )
			  . " exists. Proceeding...\n\n";
		}
		else {
			print "The directory "
			  . escapeFilePath( $cfg->param("$lcApplication.installDir") )
			  . " does not exist. Please try again.\n\n";
			$log->info( "The directory "
				  . escapeFilePath( $cfg->param("$lcApplication.installDir") )
				  . " does not exist. Please try again." );
		}
	}

	#Ask for current installed version
	genConfigItem(
		$mode,
		$cfg,
		"$lcApplication.installedVersion",
		"Please enter the version of $application that is currently installed.",
		"",
		'^[0-9]+\.([0-9]+|[0-9]+\.[0-9]+)$',
"The input you entered was not in the valid format of 'x.x.x or x.x' (where x is a version number). Please ensure you enter the version number correctly "
		  . "\n\n"
	);

	genConfigItem(
		$mode,
		$cfg,
		"$lcApplication.javaParams",
"Enter any additional parameters currently added to the JAVA RUN_OPTS for your $application install. Just press enter if you have none.",
		"",
		"",
		""
	);

	genConfigItem(
		$mode,
		$cfg,
		"$lcApplication.catalinaOpts",
"Enter any additional currently added to the Java CATALINA_OPTS for your $application install. Just press enter if you have none.",
		"",
		"",
		""
	);

	if (   $cfg->param("general.apacheProxy") eq "TRUE"
		&& $cfg->param("general.apacheProxySingleDomain") eq "FALSE" )
	{
		genConfigItem(
			$mode,
			$cfg,
			"stash.apacheProxyHost",
"Please enter the base URL Stash currently runs on (i.e. the proxyName such as yourdomain.com).",
			"",
			$hostnameRegex,
"The input you entered was not in the valid format of 'yourdomain.com' or 'subdomain.yourdomain.com'. Please try again.\n\n"
		);

		genBooleanConfigItem( $mode, $cfg, "stash.apacheProxySSL",
			"Do you currently run Stash over SSL.", "no" );

		genConfigItem(
			$mode,
			$cfg,
			"stash.apacheProxyPort",
"Please enter the port number that Apache currently serves Stash on (80 for HTTP, 443 for HTTPS in standard situations).",
			"80",
			'^([0-9]*)$',
"The input you entered was not a valid port number, please try again.\n\n"
		);
	}

	$serverSetEnvFile =
	  escapeFilePath( $cfg->param("$lcApplication.installDir") )
	  . "/bin/setenv.sh";

	$serverConfigFile =
	  escapeFilePath( $cfg->param("$lcApplication.installDir") )
	  . "/conf/server.xml";

	genBooleanConfigItem(
		$mode,
		$cfg,
		"$lcApplication.runAsService",
"Does your $application instance run as a service (i.e. runs on boot)? yes/no.",
		"yes"
	);

	#GetCrowdConfig
	@parameterNull = $cfg->param("general.externalCrowdInstance");

	if ( $#parameterNull == -1 ) {
		$externalCrowdInstance = "FALSE";
	}
	else {
		$externalCrowdInstance = $cfg->param("general.externalCrowdInstance");
	}

	if (   $externalCrowdInstance eq "TRUE"
		|| $cfg->param("crowd.enable") eq "TRUE" )
	{
		genBooleanConfigItem(
			$mode,
			$cfg,
			"stash.crowdIntegration",
"Will you be using Crowd as the authentication backend for Stash? yes/no.",
			"yes"
		);
	}
	else {
		$cfg->param( "stash.crowdIntegration", "FALSE" );
		$cfg->param( "stash.crowdSSO",         "FALSE" );
	}

	print
"Please wait, attempting to get the $application data/home directory from it's config files...\n\n";
	$log->info(
"$subname: Attempting to get $application data directory from config file $serverConfigFile."
	);

	#get data/home directory
	$returnValue =
	  getLineFromFile( $serverSetEnvFile, "STASH_HOME\\s?=", ".*=\\s?(.*)" );

	#remove quotations
	$returnValue =~ s/\"//g;

	if ( $returnValue eq "NOTFOUND" ) {
		$log->info(
"$subname: Unable to locate $application data directory. Asking user for input."
		);
		genConfigItem(
			$mode,
			$cfg,
			"$lcApplication.dataDir",
"Unable to find the data directory in the expected location in the $application config. Please enter the directory $application"
			  . "'s data is *currently* stored in.",
			"",
			'(?!^.*/$)^(/.*)',
"The input you entered was not in the valid format of '/folder'. Please ensure you enter the absolute path with a "
			  . "leading '/' and NO trailing '/'.\n\n"
		);
	}
	else {
		$cfg->param( "$lcApplication.dataDir", $returnValue );
		print
"$application data directory has been found successfully and added to the config file...\n\n";
		$log->info(
			"$subname: $application data directory found and added to config."
		);
	}

	#getContextFromFile
	$returnValue = "";

	print
"Please wait, attempting to get the $application context from it's config files...\n\n";
	$log->info(
"$subname: Attempting to get $application context from config file $serverConfigFile."
	);
	$returnValue =
	  getXMLAttribute( $serverConfigFile, "//////Context", "path" );

	if ( $returnValue eq "NOTFOUND" ) {
		$log->info(
"$subname: Unable to locate $application context. Asking user for input."
		);
		genConfigItem(
			$mode,
			$cfg,
			"$lcApplication.appContext",
"Unable to find the context in the expected location in the $application config. Please enter the context that $application currently runs under (i.e. /stash). Write NULL to blank out the context.",
			"/stash",
			'(?!^.*/$)^(/.*)',
"The input you entered was not in the valid format of '/folder'. Please ensure you enter the path with a "
			  . "leading '/' and NO trailing '/'.\n\n"
		);
	}
	else {
		if ( $returnValue eq "" ) {
			$returnValue = "NULL";
		}
		$cfg->param( "$lcApplication.appContext", $returnValue );
		print
"$application context has been found successfully and added to the config file...\n\n";
		$log->info("$subname: $application context found and added to config.");
	}

	$returnValue = "";

	print
"Please wait, attempting to get the $application connectorPort from it's config files...\n\n";
	$log->info(
"$subname: Attempting to get $application connectorPort from config file $serverConfigFile."
	);

	#Get connector port from file
	$returnValue = getXMLAttribute( $serverConfigFile, "///Connector", "port" );

	if ( $returnValue eq "NOTFOUND" ) {
		$log->info(
"$subname: Unable to locate $application connectorPort. Asking user for input."
		);
		genConfigItem(
			$mode,
			$cfg,
			"$lcApplication.connectorPort",
"Unable to find the connector port in the expected location in the $application config. Please enter the Connector port $application *currently* runs on (note this is the port you will access in the browser).",
			"8095",
			'^([0-9]*)$',
"The port number you entered contained invalid characters. Please ensure you enter only digits.\n\n"
		);
	}
	else {
		$cfg->param( "$lcApplication.connectorPort", $returnValue );
		print
"$application connectorPort has been found successfully and added to the config file...\n\n";
		$log->info(
			"$subname: $application connectorPort found and added to config.");
	}

	$returnValue = "";

	print
"Please wait, attempting to get the $application serverPort from it's config files...\n\n";
	$log->info(
"$subname: Attempting to get $application serverPort from config file $serverConfigFile."
	);

	#Get connector port from file
	$returnValue = getXMLAttribute( $serverConfigFile, "/Server", "port" );

	if ( $returnValue eq "NOTFOUND" ) {
		$log->info(
"$subname: Unable to locate $application serverPort. Asking user for input."
		);
		genConfigItem(
			$mode,
			$cfg,
			"$lcApplication.serverPort",
"Unable to find the server port in the expected location in the $application config. Please enter the Server port $application *currently* runs on (note this is the tomcat control port).",
			"8004",
			'^([0-9]*)$',
"The port number you entered contained invalid characters. Please ensure you enter only digits.\n\n"
		);
	}
	else {
		$cfg->param( "$lcApplication.serverPort", $returnValue );
		print
"$application serverPort has been found successfully and added to the config file...\n\n";
		$log->info(
			"$subname: $application serverPort found and added to config.");
	}

	$returnValue = "";

	print
"Please wait, attempting to get the $application Xms java memory parameter from it's config files...\n\n";
	$log->info(
"$subname: Attempting to get $application Xms java memory parameter from config file $serverConfigFile."
	);
	$returnValue =
	  getLineFromFile( $serverSetEnvFile, "JVM_MINIMUM_MEMORY\\s?=",
		".*=\\s?(.*)" );
	if ( $returnValue eq "NOTFOUND" ) {
		$log->info(
"$subname: Unable to locate $application Xms memory parameter. Asking user for input."
		);
		genConfigItem(
			$mode,
			$cfg,
			"$lcApplication.javaMinMemory",
"Unable to find the java Xms memory parameter in the expected location in the $application config. Please enter the minimum amount of memory *currently* assigned to $application.",
			"256m",
			'^([0-9]*m)$',
"The memory value you entered is in an invalid format. Please ensure you use the format '1234m'. (i.e. '256m')"
		);
	}
	else {
		$cfg->param( "$lcApplication.javaMinMemory", $returnValue );
		print
"$application Xms java memory parameter has been found successfully and added to the config file...\n\n";
		$log->info(
"$subname: $application Xms java memory parameter found and added to config."
		);
	}

	$returnValue = "";

	print
"Please wait, attempting to get the $application Xmx java memory parameter from it's config files...\n\n";
	$log->info(
"$subname: Attempting to get $application Xmx java memory parameter from config file $serverConfigFile."
	);
	$returnValue =
	  getLineFromFile( $serverSetEnvFile, "JVM_MAXIMUM_MEMORY\\s?=",
		".*=\\s?(.*)" );
	if ( $returnValue eq "NOTFOUND" ) {
		$log->info(
"$subname: Unable to locate $application Xmx memory parameter. Asking user for input."
		);
		genConfigItem(
			$mode,
			$cfg,
			"$lcApplication.javaMaxMemory",
"Unable to find the java Xmx memory parameter in the expected location in the $application config. Please enter the maximum amount of memory *currently* assigned to $application.",
			"512m",
			'^([0-9]*m)$',
"The memory value you entered is in an invalid format. Please ensure you use the format '1234m'. (i.e. '256m')"
		);
	}
	else {
		$cfg->param( "$lcApplication.javaMaxMemory", $returnValue );
		print
"$application Xmx java memory parameter has been found successfully and added to the config file...\n\n";
		$log->info(
"$subname: $application Xmx java memory parameter found and added to config."
		);
	}

	$returnValue = "";

	print
"Please wait, attempting to get the $application XX:MaxPermSize java memory parameter from it's config files...\n\n";
	$log->info(
"$subname: Attempting to get $application XX:MaxPermSize java memory parameter from config file $serverConfigFile."
	);

	$returnValue =
	  getLineFromFile( $serverSetEnvFile, "STASH_MAX_PERM_SIZE\\s?=",
		".*=\\s?(.*)" );
	if ( $returnValue eq "NOTFOUND" ) {
		$log->info(
"$subname: Unable to locate $application XX:MaxPermSize memory parameter. Asking user for input."
		);
		genConfigItem(
			$mode,
			$cfg,
			"$lcApplication.javaMaxPermSize",
"Unable to find the java XX:MaxPermSize memory parameter in the expected location in the $application config. Please enter the maximum amount of permGen memory *currently* assigned to $application.",
			"256m",
			'^([0-9]*m)$',
"The memory value you entered is in an invalid format. Please ensure you use the format '1234m'. (i.e. '256m')"
		);
	}
	else {
		$cfg->param( "$lcApplication.javaMaxPermSize", $returnValue );
		print
"$application XX:MaxPermSize java memory parameter has been found successfully and added to the config file...\n\n";
		$log->info(
"$subname: $application XX:MaxPermSize java memory parameter found and added to config."
		);
	}

	$returnValue = "";

	#getOSuser
	open( my $inputFileHandle,
		'<', escapeFilePath( $cfg->param("$lcApplication.installDir") ) )
	  or $log->logdie(
"Unable to open install dir for $application to test who owns it. Really this should never happen as we have already tested that the directory exists."
	  );
	my (
		$dev,   $ino,     $fileMode, $nlink, $uid,
		$gid,   $rdev,    $size,     $atime, $mtime,
		$ctime, $blksize, $blocks
	) = stat($inputFileHandle);
	$returnValue = getpwuid($uid);

	close $inputFileHandle;

	#confirmWithUserThatIsTheCorrectOSUser
	$input = getBooleanInput(
"We have detected that the user $application runs under is '$returnValue'. Is this correct? yes/no [yes]: "
	);
	print "\n";
	if ( $input eq "default" || $input eq "yes" ) {
		$cfg->param( "$lcApplication.osUser", $returnValue );
		print
		  "The osUser $returnValue has been added to the config file...\n\n";
		$log->info(
"$subname: User confirmed that the user $application runs under is $returnValue. This has been added to the config."
		);
	}
	else {
		genConfigItem(
			$mode,
			$cfg,
			"$lcApplication.osUser",
"In that case please enter the user that $application *currently* runs under.",
			"",
			'^([a-zA-Z0-9]*)$',
"The user you entered was in an invalid format. Please ensure you enter only letters and numbers without any spaces or other characters.\n\n"
		);
	}

	if (   $cfg->param("general.apacheProxy") eq "TRUE"
		&& $cfg->param("general.apacheProxySingleDomain") eq "FALSE" )
	{
		$returnValue = "";

		print
"Please wait, attempting to get the Apache proxy base hostname configuration for $application from the configuration files...\n\n";
		$log->info(
"$subname: Attempting to get $application proxyName from config file $serverConfigFile."
		);
		$returnValue =
		  getXMLAttribute( $serverConfigFile, "///Connector", "proxyName" );

		if ( $returnValue eq "NOTFOUND" ) {
			$log->info(
"$subname: Unable to locate $application proxyName. Asking user for input."
			);
			genConfigItem(
				$mode,
				$cfg,
				"$lcApplication.apacheProxyHost",
"Unable to find the base hostname attribute in the expected location in the $application config. Please enter the base URL that will be serving the site (i.e. the proxyName such as yourdomain.com).",
				"",
				$hostnameRegex,
"The input you entered was not in the valid format of 'yourdomain.com' or 'subdomain.yourdomain.com'. Please try again.\n\n"
			);
		}
		else {
			$cfg->param( "$lcApplication.apacheProxyHost", $returnValue );
			print
"$application base hostname has been found successfully and added to the config file...\n\n";
			$log->info(
"$subname: $application base hostname found and added to config."
			);
		}

		$returnValue = "";

		print
"Please wait, attempting to get the Apache proxy scheme configuration for $application from the configuration files...\n\n";
		$log->info(
"$subname: Attempting to get $application proxy scheme from config file $serverConfigFile."
		);
		$returnValue =
		  getXMLAttribute( $serverConfigFile, "///Connector", "scheme" );

		if ( $returnValue eq "NOTFOUND" ) {
			$log->info(
"$subname: Unable to locate $application proxy scheme. Asking user for input."
			);
			genBooleanConfigItem(
				$mode,
				$cfg,
				"$lcApplication.apacheProxySSL",
"Unable to locate the Apache proxy scheme configuration in $application config. Will you be running $application over SSL.",
				"no"
			);
		}
		else {
			if ( $returnValue eq "http" ) {
				$log->info(
"$subname: return value for Apache Proxy Scheme config is 'http'."
				);
				$cfg->param( "$lcApplication.apacheProxySSL", "FALSE" );
			}
			elsif ( $returnValue eq "https" ) {
				$log->info(
"$subname: return value for Apache Proxy Scheme config is 'http'."
				);
				$cfg->param( "$lcApplication.apacheProxySSL", "TRUE" );
			}
			else {
				$log->info(
"$subname: return value for Apache Proxy Scheme config is 'UNKNOWN' This is not good."
				);
				$cfg->param( "$lcApplication.apacheProxySSL", "UNKNOWN" );
			}
			print
"$application Apache Proxy scheme has been found successfully and added to the config file...\n\n";
			$log->info(
				"$subname: $application proxy scheme found and added to config."
			);
		}

		$returnValue = "";

		print
"Please wait, attempting to get the Apache proxy port configuration for $application from the configuration files...\n\n";
		$log->info(
"$subname: Attempting to get $application proxyPort from config file $serverConfigFile."
		);
		$returnValue =
		  getXMLAttribute( $serverConfigFile, "///Connector", "proxyPort" );

		if ( $returnValue eq "NOTFOUND" ) {
			$log->info(
"$subname: Unable to locate $application proxyPort. Asking user for input."
			);
			genConfigItem(
				$mode,
				$cfg,
				"$lcApplication.apacheProxyPort",
"Unable to find the Apache proxy port attribute in the expected location in the $application config. Please enter the port number that Apache currently serves on (80 for HTTP, 443 for HTTPS in standard situations).",
				"80/443",
				'^([0-9]*)$',
"The input you entered was not a valid port number, please try again.\n\n"
			);
		}
		else {
			$cfg->param( "$lcApplication.apacheProxyPort", $returnValue );
			print
"$application base hostname has been found successfully and added to the config file...\n\n";
			$log->info(
"$subname: $application base hostname found and added to config."
			);
		}
	}

	#Set up some defaults for Stash
	$cfg->param( "$lcApplication.tomcatDir",               "" );
	$cfg->param( "$lcApplication.webappDir",               "/atlassian-stash" );
	$cfg->param( "$lcApplication.processSearchParameter1", "java" );
	$cfg->param( "$lcApplication.processSearchParameter2",
		"classpath " . $cfg->param("$lcApplication.installDir") );

	$cfg->write($configFile);
	loadSuiteConfig();

	print
"We now have the $application config and it has been written to the config file. Please press enter to continue.\n";
	$input = <STDIN>;
}

########################################
#GenerateStashConfig                   #
########################################
sub generateStashConfig {
	my $cfg;
	my $mode;
	my $defaultValue;
	my $subname = ( caller(0) )[3];
	my $externalCrowdInstance;
	my $application = "Stash";
	my @parameterNull;

	$log->debug("BEGIN: $subname");

	$mode = $_[0];
	$cfg  = $_[1];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_mode", $mode );

	genConfigItem(
		$mode,
		$cfg,
		"stash.installDir",
		"Please enter the directory Stash will be installed into.",
		$cfg->param("general.rootInstallDir") . "/stash",
		'(?!^.*/$)^(/.*)',
"The input you entered was not in the valid format of '/folder'. Please ensure you enter the absolute path with a "
		  . "leading '/' and NO trailing '/'.\n\n"
	);

	genConfigItem(
		$mode,
		$cfg,
		"stash.dataDir",
		"Please enter the directory Stash's data will be stored in.",
		$cfg->param("general.rootDataDir") . "/stash",
		'(?!^.*/$)^(/.*)',
"The input you entered was not in the valid format of '/folder'. Please ensure you enter the absolute path with a "
		  . "leading '/' and NO trailing '/'.\n\n"
	);

	genConfigItem(
		$mode,
		$cfg,
		"stash.osUser",
		"Enter the user that Stash will run under.",
		"stash",
		'^([a-zA-Z0-9]*)$',
"The user you entered was in an invalid format. Please ensure you enter only letters and numbers without any spaces or other characters.\n\n"
	);

	genConfigItem(
		$mode,
		$cfg,
		"stash.appContext",
"Enter the context that Stash should run under (i.e. /stash). Write NULL to blank out the context.",
		"/stash",
		'(?!^.*/$)^(/.*)',
"The input you entered was not in the valid format of '/folder'. Please ensure you enter the path with a "
		  . "leading '/' and NO trailing '/'.\n\n"
	);
	genConfigItem(
		$mode,
		$cfg,
		"stash.connectorPort",
"Please enter the Connector port Stash will run on (note this is the port you will access in the browser).",
		"7990",
		'^([0-9]*)$',
"The port number you entered contained invalid characters. Please ensure you enter only digits.\n\n"
	);
	checkConfiguredPort( $application, "stash.connectorPort", $cfg );

	genConfigItem(
		$mode,
		$cfg,
		"stash.serverPort",
"Please enter the SERVER port Stash will run on (note this is the control port not the port you access in a browser).",
		"8004",
		'^([0-9]*)$',
"The port number you entered contained invalid characters. Please ensure you enter only digits.\n\n"
	);

	checkConfiguredPort( $application, "stash.serverPort", $cfg );

	genConfigItem(
		$mode,
		$cfg,
		"stash.javaParams",
"Enter any additional parameters you would like to add to the Java RUN_OPTS.",
		"",
		"",
		""
	);

	genConfigItem(
		$mode,
		$cfg,
		"stash.catalinaOpts",
"Enter any additional parameters you would like to add to the Java CATALINA_OPTS.",
		"",
		"",
		""
	);

	genConfigItem(
		$mode,
		$cfg,
		"stash.javaMinMemory",
		"Enter the minimum amount of memory you would like to assign to Stash.",
		"512m",
		'^([0-9]*m)$',
"The memory value you entered is in an invalid format. Please ensure you use the format '1234m'. (i.e. '256m')"
	);

	genConfigItem(
		$mode,
		$cfg,
		"stash.javaMaxMemory",
		"Enter the maximum amount of memory you would like to assign to Stash.",
		"768m",
		'^([0-9]*m)$',
"The memory value you entered is in an invalid format. Please ensure you use the format '1234m'. (i.e. '256m')"
	);

	genConfigItem(
		$mode,
		$cfg,
		"stash.javaMaxPermSize",
"Enter the amount of memory for the MAX_PERM_SIZE parameter that you would like to assign to Stash.",
		"256m",
		'^([0-9]*m)$',
"The memory value you entered is in an invalid format. Please ensure you use the format '1234m'. (i.e. '256m')"
	);

	if (   $cfg->param("general.apacheProxy") eq "TRUE"
		&& $cfg->param("general.apacheProxySingleDomain") eq "FALSE" )
	{
		genConfigItem(
			$mode,
			$cfg,
			"stash.apacheProxyHost",
"Please enter the base URL that will be serving the site (i.e. the proxyName such as yourdomain.com).",
			"",
			$hostnameRegex,
"The input you entered was not in the valid format of 'yourdomain.com' or 'subdomain.yourdomain.com'. Please try again.\n\n"
		);

		genBooleanConfigItem( $mode, $cfg, "stash.apacheProxySSL",
			"Will you be running Stash over SSL.", "no" );

		genConfigItem(
			$mode,
			$cfg,
			"stash.apacheProxyPort",
"Please enter the port number that Apache will serve on (80 for HTTP, 443 for HTTPS in standard situations).",
			"80",
			'^([0-9]*)$',
"The input you entered was not a valid port number, please try again.\n\n"
		);
	}

	genBooleanConfigItem( $mode, $cfg, "stash.runAsService",
		"Would you like to run Stash as a service? yes/no.", "yes" );

	#GetCrowdConfig
	@parameterNull = $cfg->param("general.externalCrowdInstance");

	if ( $#parameterNull == -1 ) {
		$externalCrowdInstance = "FALSE";
	}
	else {
		$externalCrowdInstance = $cfg->param("general.externalCrowdInstance");
	}

	if (   $externalCrowdInstance eq "TRUE"
		|| $cfg->param("crowd.enable") eq "TRUE" )
	{
		genBooleanConfigItem(
			$mode,
			$cfg,
			"stash.crowdIntegration",
"Will you be using Crowd as the authentication backend for Stash? yes/no.",
			"yes"
		);
	}
	else {
		$cfg->param( "stash.crowdIntegration", "FALSE" );
		$cfg->param( "stash.crowdSSO",         "FALSE" );
	}

	#Set up some defaults for Stash
	$cfg->param( "stash.tomcatDir",               "" );
	$cfg->param( "stash.webappDir",               "/atlassian-stash" );
	$cfg->param( "stash.processSearchParameter1", "java" );
	$cfg->param( "stash.processSearchParameter2",
		"classpath " . $cfg->param("stash.installDir") );

	$cfg->param( "stash.enable", "TRUE" );
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
	my @parameterNull;
	my $javaOptsValue;
	my $catalinaOptsValue;
	my @requiredConfigItems;
	my $homeSearchParam;
	my $homeSearchReplace;
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	#Set up list of config items that are requred for this install to run
	$lcApplication       = lc($application);
	@requiredConfigItems = (
		"stash.appContext",              "stash.enable",
		"stash.dataDir",                 "stash.installDir",
		"stash.runAsService",            "stash.serverPort",
		"stash.connectorPort",           "stash.osUser",
		"stash.webappDir",               "stash.javaMinMemory",
		"stash.javaMaxMemory",           "stash.javaMaxPermSize",
		"stash.processSearchParameter1", "stash.processSearchParameter2",
		"stash.crowdIntegration"
	);

	if ( $globalConfig->param("general.apacheProxy") eq "TRUE" ) {
		if (
			$globalConfig->param("general.apacheProxySingleDomain") eq "FALSE" )
		{
			push( @requiredConfigItems, "stash.apacheProxyPort" );
			push( @requiredConfigItems, "stash.apacheProxySSL" );
			push( @requiredConfigItems, "stash.apacheProxyHost" );
		}
	}

	#Run generic installer steps
	installGeneric( $application, $downloadArchivesUrl, \@requiredConfigItems );
	$osUser = $globalConfig->param("$lcApplication.osUser")
	  ; #we get this after install in CASE the installer changes the configured user in future

	#Force update config items for search parameters
	$globalConfig->param( "$lcApplication.processSearchParameter1", "java" );
	$globalConfig->param( "$lcApplication.processSearchParameter2",
		"classpath " . $globalConfig->param("$lcApplication.installDir") );
	$globalConfig->write($configFile);
	loadSuiteConfig();

	#Perform application specific configuration
	print "Applying configuration settings to the install, please wait...\n\n";

	$serverXMLFile =
	  escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
	  . "/conf/server.xml";

	$initPropertiesFile =
	  escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
	  . "/bin/setenv.sh";

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

	print "Applying Apache Proxy parameters to config...\n\n";

	#Update the server config with reverse proxy configuration
	$log->info( "$subname: Updating the reverse proxy configuration in "
		  . $serverXMLFile );
	print "Applying Apache proxy parameters to config...\n\n";
	if ( $globalConfig->param("general.apacheProxy") eq "TRUE" ) {
		if ( $globalConfig->param("general.apacheProxySingleDomain") eq "TRUE" )
		{
			updateXMLAttribute( $serverXMLFile, "///Connector", "proxyName",
				$globalConfig->param("general.apacheProxyHost") );

			if ( $globalConfig->param("general.apacheProxySSL") eq "TRUE" ) {
				updateXMLAttribute( $serverXMLFile, "///Connector", "scheme",
					"https" );
			}
			else {
				updateXMLAttribute( $serverXMLFile, "///Connector", "scheme",
					"http" );
			}
			updateXMLAttribute( $serverXMLFile, "///Connector", "secure",
				"false" );
			updateXMLAttribute( $serverXMLFile, "///Connector", "proxyPort",
				$globalConfig->param("general.apacheProxyPort") );
		}
		else {
			updateXMLAttribute( $serverXMLFile, "///Connector", "proxyName",
				$globalConfig->param("$lcApplication.apacheProxyHost") );
			if ( $globalConfig->param("$lcApplication.apacheProxySSL") eq
				"TRUE" )
			{
				updateXMLAttribute( $serverXMLFile, "///Connector", "scheme",
					"https" );
			}
			else {
				updateXMLAttribute( $serverXMLFile, "///Connector", "scheme",
					"http" );
			}
			updateXMLAttribute( $serverXMLFile, "///Connector", "secure",
				"false" );
			updateXMLAttribute( $serverXMLFile, "///Connector", "proxyPort",
				$globalConfig->param("$lcApplication.apacheProxyPort") );
		}
	}

	print "Applying home directory location to config...\n\n";

#Check if we are installing version below 3.4.3 to maintain backwards compatibility see [#ATLASMGR-397]
	if (
		compareTwoVersions(
			$globalConfig->param("$lcApplication.installedVersion"), "3.4.3" )
		ne "GREATER"
	  )
	{
		$homeSearchParam = "STASH_HOME=";
		$homeSearchReplace =
		    "STASH_HOME=\""
		  . escapeFilePath( $globalConfig->param("$lcApplication.dataDir") )
		  . "\"";
	}
	else {
		$homeSearchParam = "export STASH_HOME=";
		$homeSearchReplace =
		    "export STASH_HOME=\""
		  . escapeFilePath( $globalConfig->param("$lcApplication.dataDir") )
		  . "\"";
	}

	#Edit Stash config file to reference homedir
	$log->info( "$subname: Applying homedir in " . $initPropertiesFile );
	print "Applying home directory to config...\n\n";
	updateLineInFile(
		$initPropertiesFile, $homeSearchParam,
		$homeSearchReplace,  "#STASH_HOME="
	);

	@parameterNull = $globalConfig->param("$lcApplication.javaParams");
	if (   ( $#parameterNull == -1 )
		|| $globalConfig->param("$lcApplication.javaParams") eq ""
		|| $globalConfig->param("$lcApplication.javaParams") eq "default" )
	{
		$javaOptsValue = "NOJAVAOPTSCONFIGSPECIFIED";
	}
	else {
		$javaOptsValue = "CONFIGSPECIFIED";
	}

	#Apply the JavaOpts configuration (if any)
	print "Applying Java_Opts configuration to install...\n\n";
	if ( $javaOptsValue ne "NOJAVAOPTSCONFIGSPECIFIED" ) {
		updateJavaOpts(
			escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
			  . "/bin/setenv.sh",
			"JVM_REQUIRED_ARGS",
			getConfigItem( "$lcApplication.javaParams", $globalConfig )
		);
	}

	#Apply Catalina Opts to Install
	@parameterNull = $globalConfig->param("$lcApplication.catalinaOpts");
	if (   ( $#parameterNull == -1 )
		|| $globalConfig->param("$lcApplication.catalinaOpts") eq ""
		|| $globalConfig->param("$lcApplication.catalinaOpts") eq "default" )
	{
		$catalinaOptsValue = "NOCATALINAOPTSCONFIGSPECIFIED";
	}
	else {
		$catalinaOptsValue = "CONFIGSPECIFIED";
	}

	print "Applying CATALINA_OPTS configuration to install...\n\n";
	if ( $javaOptsValue ne "NOCATALINAOPTSCONFIGSPECIFIED" ) {
		updateCatalinaOpts(
			$application,
			escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
			  . "/bin/setenv.sh",
			"CATALINA_OPTS=",
			getConfigItem( "$lcApplication.catalinaOpts", $globalConfig )
		);
	}

	print "Configuration settings have been applied successfully.\n\n";

	#Run any additional steps

	#Update Java Memory Parameters
	print "Applying Java memory configuration to install...\n\n";
	$log->info(
		"$subname: Applying Java memory parameters to " . $initPropertiesFile );
	updateLineInFile(
		$initPropertiesFile,
		"JVM_MINIMUM_MEMORY",
		"JVM_MINIMUM_MEMORY="
		  . $globalConfig->param("$lcApplication.javaMinMemory"),
		"#JVM_MINIMUM_MEMORY="
	);

	updateLineInFile(
		$initPropertiesFile,
		"JVM_MAXIMUM_MEMORY",
		"JVM_MAXIMUM_MEMORY="
		  . $globalConfig->param("$lcApplication.javaMaxMemory"),
		"#JVM_MAXIMUM_MEMORY="
	);

	updateLineInFile(
		$initPropertiesFile,
		"STASH_MAX_PERM_SIZE",
		"STASH_MAX_PERM_SIZE="
		  . $globalConfig->param("$lcApplication.javaMaxPermSize"),
		"#STASH_MAX_PERM_SIZE="
	);

	#Generate the init.d file
	print
"Setting up initd files and run as a service (if configured) please wait...\n\n";
	$log->info("$subname: Generating init.d file for $application.");

	generateInitD(
		$application,
		$osUser,
		escapeFilePath( $globalConfig->param("$lcApplication.installDir") ),
		"/bin/start-stash.sh",
		"/bin/stop-stash.sh",
		$globalConfig->param("$lcApplication.processSearchParameter1"),
		$globalConfig->param("$lcApplication.processSearchParameter2")
	);

	#Finally run generic post install tasks
	postInstallGeneric($application);
}

########################################
#Uninstall Stash                       #
########################################
sub uninstallStash {
	my $application = "Stash";
	uninstallGeneric($application);
}

########################################
#Upgrade Stash                         #
########################################
sub upgradeStash {
	my $application = "Stash";
	my $osUser;
	my $lcApplication;
	my $downloadArchivesUrl =
	  "http://www.atlassian.com/it/software/stash/download-archives";
	my $serverXMLFile;
	my $initPropertiesFile;
	my $javaMemParameterFile;
	my @requiredConfigItems;
	my @parameterNull;
	my $javaOptsValue;
	my $catalinaOptsValue;
	my $homeSearchParam;
	my $homeSearchReplace;
	my $subname = ( caller(0) )[3];

	$log->debug("BEGIN: $subname");

	#Set up list of config items that are requred for this install to run
	$lcApplication       = lc($application);
	@requiredConfigItems = (
		"stash.appContext",              "stash.enable",
		"stash.dataDir",                 "stash.installDir",
		"stash.runAsService",            "stash.serverPort",
		"stash.connectorPort",           "stash.osUser",
		"stash.webappDir",               "stash.javaMinMemory",
		"stash.javaMaxMemory",           "stash.javaMaxPermSize",
		"stash.processSearchParameter1", "stash.processSearchParameter2",
		"stash.crowdIntegration"
	);

	if ( $globalConfig->param("general.apacheProxy") eq "TRUE" ) {
		if (
			$globalConfig->param("general.apacheProxySingleDomain") eq "FALSE" )
		{
			push( @requiredConfigItems, "stash.apacheProxyPort" );
			push( @requiredConfigItems, "stash.apacheProxySSL" );
			push( @requiredConfigItems, "stash.apacheProxyHost" );
		}
	}

	#Force update config items for search parameters
	$globalConfig->param( "$lcApplication.processSearchParameter1", "java" );
	$globalConfig->param( "$lcApplication.processSearchParameter2",
		"classpath " . $globalConfig->param("$lcApplication.installDir") );
	$globalConfig->write($configFile);
	loadSuiteConfig();

	#Run generic installer steps
	upgradeGeneric( $application, $downloadArchivesUrl, \@requiredConfigItems );
	$osUser = $globalConfig->param("$lcApplication.osUser")
	  ; #we get this after install in CASE the installer changes the configured user in future

	#Perform application specific configuration
	print "Applying configuration settings to the install, please wait...\n\n";

	$serverXMLFile =
	  escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
	  . "/conf/server.xml";

	$initPropertiesFile =
	  escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
	  . "/bin/setenv.sh";

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

	#Update the server config with reverse proxy configuration
	$log->info( "$subname: Updating the reverse proxy configuration in "
		  . $serverXMLFile );
	print "Applying Apache proxy parameters to config...\n\n";
	if ( $globalConfig->param("general.apacheProxy") eq "TRUE" ) {
		if ( $globalConfig->param("general.apacheProxySingleDomain") eq "TRUE" )
		{
			updateXMLAttribute( $serverXMLFile, "///Connector", "proxyName",
				$globalConfig->param("general.apacheProxyHost") );

			if ( $globalConfig->param("general.apacheProxySSL") eq "TRUE" ) {
				updateXMLAttribute( $serverXMLFile, "///Connector", "scheme",
					"https" );
			}
			else {
				updateXMLAttribute( $serverXMLFile, "///Connector", "scheme",
					"http" );
			}
			updateXMLAttribute( $serverXMLFile, "///Connector", "secure",
				"false" );
			updateXMLAttribute( $serverXMLFile, "///Connector", "proxyPort",
				$globalConfig->param("general.apacheProxyPort") );
		}
		else {
			updateXMLAttribute( $serverXMLFile, "///Connector", "proxyName",
				$globalConfig->param("$lcApplication.apacheProxyHost") );

			if ( $globalConfig->param("$lcApplication.apacheProxySSL") eq
				"TRUE" )
			{
				updateXMLAttribute( $serverXMLFile, "///Connector", "scheme",
					"https" );
			}
			else {
				updateXMLAttribute( $serverXMLFile, "///Connector", "scheme",
					"http" );
			}
			updateXMLAttribute( $serverXMLFile, "///Connector", "secure",
				"false" );
			updateXMLAttribute( $serverXMLFile, "///Connector", "proxyPort",
				$globalConfig->param("$lcApplication.apacheProxyPort") );
		}
	}

	print "Applying home directory location to config...\n\n";

#Check if we are installing version below 3.4.3 to maintain backwards compatibility see [#ATLASMGR-397]
	if (
		compareTwoVersions(
			$globalConfig->param("$lcApplication.installedVersion"), "3.4.3" )
		ne "GREATER"
	  )
	{
		$homeSearchParam = "STASH_HOME=";
		$homeSearchReplace =
		    "STASH_HOME=\""
		  . escapeFilePath( $globalConfig->param("$lcApplication.dataDir") )
		  . "\"";
	}
	else {
		$homeSearchParam = "export STASH_HOME=";
		$homeSearchReplace =
		    "export STASH_HOME=\""
		  . escapeFilePath( $globalConfig->param("$lcApplication.dataDir") )
		  . "\"";
	}

	#Edit Stash config file to reference homedir
	$log->info( "$subname: Applying homedir in " . $initPropertiesFile );
	print "Applying home directory to config...\n\n";
	updateLineInFile(
		$initPropertiesFile, $homeSearchParam,
		$homeSearchReplace,  "#STASH_HOME="
	);

	@parameterNull = $globalConfig->param("$lcApplication.javaParams");
	if (   ( $#parameterNull == -1 )
		|| $globalConfig->param("$lcApplication.javaParams") eq ""
		|| $globalConfig->param("$lcApplication.javaParams") eq "default" )
	{
		$javaOptsValue = "NOJAVAOPTSCONFIGSPECIFIED";
	}
	else {
		$javaOptsValue = "CONFIGSPECIFIED";
	}

	#Apply the JavaOpts configuration (if any)
	print "Applying Java_Opts configuration to install...\n\n";
	if ( $javaOptsValue ne "NOJAVAOPTSCONFIGSPECIFIED" ) {
		updateJavaOpts(
			escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
			  . "/bin/setenv.sh",
			"JVM_REQUIRED_ARGS",
			getConfigItem( "$lcApplication.javaParams", $globalConfig )
		);
	}

	#Apply Catalina Opts to Install
	@parameterNull = $globalConfig->param("$lcApplication.catalinaOpts");
	if (   ( $#parameterNull == -1 )
		|| $globalConfig->param("$lcApplication.catalinaOpts") eq ""
		|| $globalConfig->param("$lcApplication.catalinaOpts") eq "default" )
	{
		$catalinaOptsValue = "NOCATALINAOPTSCONFIGSPECIFIED";
	}
	else {
		$catalinaOptsValue = "CONFIGSPECIFIED";
	}

	print "Applying CATALINA_OPTS configuration to install...\n\n";
	if ( $javaOptsValue ne "NOCATALINAOPTSCONFIGSPECIFIED" ) {
		updateCatalinaOpts(
			$application,
			escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
			  . "/bin/setenv.sh",
			"CATALINA_OPTS=",
			getConfigItem( "$lcApplication.catalinaOpts", $globalConfig )
		);
	}

	print "Configuration settings have been applied successfully.\n\n";

	#Run any additional steps

	#Update Java Memory Parameters
	print "Applying Java memory configuration to install...\n\n";
	$log->info(
		"$subname: Applying Java memory parameters to " . $initPropertiesFile );
	updateLineInFile(
		$initPropertiesFile,
		"JVM_MINIMUM_MEMORY",
		"JVM_MINIMUM_MEMORY="
		  . $globalConfig->param("$lcApplication.javaMinMemory"),
		"#JVM_MINIMUM_MEMORY="
	);

	updateLineInFile(
		$initPropertiesFile,
		"JVM_MAXIMUM_MEMORY",
		"JVM_MAXIMUM_MEMORY="
		  . $globalConfig->param("$lcApplication.javaMaxMemory"),
		"#JVM_MAXIMUM_MEMORY="
	);

	updateLineInFile(
		$initPropertiesFile,
		"STASH_MAX_PERM_SIZE",
		"STASH_MAX_PERM_SIZE="
		  . $globalConfig->param("$lcApplication.javaMaxPermSize"),
		"#STASH_MAX_PERM_SIZE="
	);

	#Generate the init.d file
	print
"Setting up initd files and run as a service (if configured) please wait...\n\n";
	$log->info("$subname: Generating init.d file for $application.");
	generateInitD(
		$application,
		$osUser,
		escapeFilePath( $globalConfig->param("$lcApplication.installDir") ),
		"/bin/start-stash.sh",
		"/bin/stop-stash.sh",
		$globalConfig->param("$lcApplication.processSearchParameter1"),
		$globalConfig->param("$lcApplication.processSearchParameter2")
	);

	#Finally run generic post install tasks
	postUpgradeGeneric($application);
}

#######################################################################
#END STASH MANAGER FUNCTIONS                                          #
#######################################################################

bootStrapper();
