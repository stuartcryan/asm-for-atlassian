#!/usr/bin/perl

#
#    Copyright 2012-2013 Stuart Ryan
#
#    Application Name: AtlassianSuiteManager
#    Application URI: http://technicalnotebook.com/wiki/display/ATLASSIANMGR/Atlassian+Suite+Manager+Script+Home
#    Version: 0.1
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

use LWP::Simple qw($ua getstore get is_success);
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
use Archive::Extract;
use FindBin '$Bin';
use XML::Twig;
use Socket qw( PF_INET SOCK_STREAM INADDR_ANY sockaddr_in );
use Errno qw( EADDRINUSE );
use Getopt::Long;
use Log::Log4perl;
use Filesys::DfPortable;
use strict;      # Good practice
use warnings;    # Good practice

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
my $autoMode                = '';    #global flag for command line paramaters
my $globalArch;
my @suiteApplications =
  ( "Bamboo", "Confluence", "Crowd", "Fisheye", "JIRA", "Stash" );
my $log = Log::Log4perl->get_logger("");
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
	my ($fd);
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	$application   = $_[0];
	$lcApplication = lc($application);

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_application", $application );

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
	  dirSize(
		escapeFilePath( $globalConfig->param("$lcApplication.installDir") ) );
	$dataDirSize =
	  dirSize(
		escapeFilePath( $globalConfig->param("$lcApplication.dataDir") ) );

	$installDirRef =
	  dfportable(
		escapeFilePath( $globalConfig->param("$lcApplication.installDir") ) );
	$dataDirRef =
	  dfportable(
		escapeFilePath( $globalConfig->param("$lcApplication.dataDir") ) );

	$installDriveFreeSpace = $installDirRef->{bfree};
	$dataDriveFreeSpace    = $dataDirRef->{bfree};

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

	print "Backing up $application installation directory...\n\n";
	copyDirectory(
		escapeFilePath( $globalConfig->param("$lcApplication.installDir") ),
		$applicationDirBackupDirName );
	$globalConfig->param( "$lcApplication.latestInstallDirBackupLocation",
		$applicationDirBackupDirName );

	print
"$application installation successfully backed up to $applicationDirBackupDirName. \n\n";

	print "Backing up $application data directory...\n\n";
	copyDirectory(
		escapeFilePath( $globalConfig->param("$lcApplication.dataDir") ),
		$dataDirBackupDirName );
	$globalConfig->param( "$lcApplication.latestDataDirBackupLocation",
		$dataDirBackupDirName );

	print
"$application data directory successfully backed up to $dataDirBackupDirName. \n\n";

	print "Tidying up... please wait... \n\n";

	$log->info(
"Writing out config file to disk following new application backup being taken."
	);
	$globalConfig->write($configFile);
	loadSuiteConfig();

	$log->debug(
"$subname: Doing recursive chown of $applicationDirBackupDirName and $dataDirBackupDirName to "
		  . $globalConfig->param("$lcApplication.osUser")
		  . "." );
	chownRecursive( $globalConfig->param("$lcApplication.osUser"),
		$applicationDirBackupDirName );
	chownRecursive( $globalConfig->param("$lcApplication.osUser"),
		$dataDirBackupDirName );

	print
"A backup of $application has been taken. Please note, this script can only backup your application and data directories.\n"
	  . "It is imperative that you take a backup of your database. You should do so now. If you attempt a rollback with this script, you must still MANUALLY\n"
	  . "restore your database. This script DOES NOT RESTORE YOUR DATABASE!!!\n\n";

	print
"Please press enter to confirm you have read and thorougly understand the above warning regarding database restores.";
	my $input = <STDIN>;
	print "\n\n";
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
				$log->debug("Port is available.");
				$LOOP = 0;
			}
			else {
				$log->debug("Port is in use.");

				$input = getBooleanInput(
"The port you have configured ($configValue) for $configItem is currently in use, this may be expected if you are already running the application."
					  . "\nOtherwise you may need to configure another port.\n\nWould you like to configure a different port? yes/no [yes]: "
				);
				print "\n";
				if (   $input eq "yes"
					|| $input eq "default" )
				{
					$log->debug("User selected to configure new port.");
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
					$log->debug("User selected to keep existing port.");
				}
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

	$log->info("BEGIN: $subname");

	$inputFile      = $_[0];
	$lineReference  = $_[1];    #the line we are looking for
	$newLine        = $_[2];    #the line we want to add
	$lineReference2 = $_[3];    #the #! line we expect

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
"No line containing \"$lineReference2\" found in file $inputFile\n\n"
				);
			}

			#Otherwise add the new line after the found line
			else {
				$log->info(
					"$subname: Replacing '$data[$index1]' with $newLine.");
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
#dirSize - Calculate Directory Size    #
########################################
sub dirSize {

#code written by docsnider on http://bytes.com/topic/perl/answers/603354-calculate-size-all-files-directory
	my ($dir)  = $_[0];
	my ($size) = 0;
	my ($fd);
	my $subname = ( caller(0) )[3];
	$log->info("BEGIN: $subname");

	opendir( $fd, $dir )
	  or $log->logdie(
"Unable to open directory to calculate the directory size. Unable to continue: $!"
	  );

	for my $item ( readdir($fd) ) {
		next if ( $item =~ /^\.\.?$/ );

		my ($path) = "$dir/$item";

		$size += (
			( -d $path )
			? dirSize($path)
			: ( -f $path ? ( stat($path) )[7] : 0 )
		);
	}

	closedir($fd);

	$log->info("Total directory size for $dir is $size bytes.");

	return ($size);
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

	$log->info("BEGIN: $subname");

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

	print "Beginning download of $lcApplication, please wait...\n\n";

	#Get the URL for the version we want to download
	if ( $type eq "LATEST" ) {
		$log->debug("$subname: Downloading latest version of $application");
		@downloadDetails =
		  getLatestDownloadURL( $lcApplication, $architecture );
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
	if ( isSupportedVersion( $lcApplication, $downloadDetails[1] ) eq "no" ) {
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
			$log->info(
"$subname: User has opted to download $version of $application even though it has not been tested with this script."
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

	$log->info("BEGIN: $subname");

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

	$log->info("BEGIN: $subname");

	$architecture = $_[0];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_architecture", $architecture );

	#Configure all products in the suite
	@suiteProducts =
	  ( 'Crowd', 'Confluence', 'JIRA', 'Fisheye', 'Bamboo', 'Stash' );

	#Iterate through each of the products, get the URL and download
	foreach (@suiteProducts) {
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
	$log->info("$subname: Extracting $inputFile");

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
	$log->info("$subname: Extract completed.");

	#Check for existing folder and provide option to backup
	if ( -d $expectedFolderName ) {
		if ( $mode eq "UPGRADE" ) {
			print "Deleting old install directory please wait...\n\n";
			rmtree( ["$expectedFolderName"] );

			$log->info(
				"$subname: Moving $ae->extract_path() to $expectedFolderName");
			moveDirectory( $ae->extract_path(), $expectedFolderName );
			$log->info("$subname: Chowning $expectedFolderName to $osUser");
			chownRecursive( $osUser, $expectedFolderName );
		}
		else {
			my $LOOP = 1;
			my $input;
			$log->info("$subname: $expectedFolderName already exists.");
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
		print FH 'backup' . "$application" . '$Boolean=true' . "\n";
	}
	if ( $mode eq "INSTALL" ) {
		print FH 'rmiPort$Long='
		  . $globalConfig->param( $lcApplication . ".serverPort" ) . "\n";
		print FH "app.confHome="
		  . escapeFilePath( $globalConfig->param("$lcApplication.dataDir") )
		  . "\n";
	}
	if ( $globalConfig->param( $lcApplication . ".runAsService" ) eq "TRUE" ) {
		print FH 'app.install.service$Boolean=true' . "\n";
	}
	else {
		print FH 'app.install.service$Boolean=false' . "\n";
	}
	print FH "existingInstallationDir="
	  . escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
	  . "\n";

	if ( $mode eq "UPGRADE" ) {
		print FH "sys.confirmedUpdateInstallationString=true" . "\n";
	}
	else {
		print FH "sys.confirmedUpdateInstallationString=false" . "\n";
	}
	print FH "sys.languageId=en" . "\n";
	if ( $mode eq "INSTALL" ) {
		print FH "sys.installationDir="
		  . escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
		  . "\n";
	}
	print FH 'executeLauncherAction$Boolean=false' . "\n";
	if ( $mode eq "INSTALL" ) {
		print FH 'httpPort$Long='
		  . $globalConfig->param( $lcApplication . ".connectorPort" ) . "\n";
		print FH "portChoice=custom" . "\n";
	}
	close FH;
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
			"# Provides:          $lcApplication\n",
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

	push( @initSpecific, @initGeneric );

	#Write out file to /etc/init.d
	$log->info("$subname: Writing out init.d file for $application.");
	open FILE, ">/etc/init.d/$lcApplication"
	  or $log->logdie("Unable to open file /etc/init.d/$lcApplication: $!");
	print FILE @initSpecific;
	close FILE;

	#Make the new init.d file executable
	$log->info("$subname: Chmodding init.d file for $lcApplication.");
	chmod 0755, "/etc/init.d/$lcApplication"
	  or $log->logdie("Couldn't chmod /etc/init.d/$lcApplication: $!");
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

	$log->info("BEGIN: $subname");

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

	while ( $LOOP == 1 ) {
		print $messageText . " [" . $defaultValue . "]: ";
		$input = getGenericInput();
		print "\n";

#If default option is selected (i.e. just a return), use default value, otherwise use input
		if ( $input eq "default" && $defaultInputValue ne "" ) {
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
				'^([a-zA-Z0-9\.]*)$',
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

	#Get Crowd configuration
	genBooleanConfigItem( $mode, $cfg, "crowd.enable",
		"Do you wish to install/manage Crowd? yes/no ", "yes" );

	if ( $cfg->param("crowd.enable") eq "TRUE" ) {

		$input = getBooleanInput(
			"Do you wish to set up/update the Crowd configuration now? [no]: ");

		if ( $input eq "yes" ) {
			print "\n";
			generateCrowdConfig( $mode, $cfg );
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
			"Do you wish to set up/update the Stash configuration now? [no]: ");

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
		( ( $#parameterNull == -1 ) || $cfg->param("general.dbJDBCJar") eq "" )
	  )
	{
		$log->info(
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
			$log->info(
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
#getEnvironmentVars                    #
########################################
sub getEnvironmentVars {
	my $inputFile;    #Must Be Absolute Path
	my $searchFor;
	my @data;
	my $referenceVar;
	my $returnValue;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	$inputFile    = $_[0];
	$referenceVar = $_[1];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_inputFile",    $inputFile );
	dumpSingleVarToLog( "$subname" . "_referenceVar", $referenceVar );

	#Try to open the provided file
	open( FILE, $inputFile )
	  or $log->logdie("Unable to open file: $inputFile");

	# read file into an array
	@data = <FILE>;

	close(FILE);

	#Search for the definition of the provided variable
	$searchFor = "$referenceVar=";
	my ($index1) = grep { $data[$_] =~ /^$searchFor.*/ } 0 .. $#data;

#If no result is found insert a new line before the line found above which contains the JAVA_OPTS variable
	if ( !defined($index1) ) {
		$log->info("$subname: $referenceVar= not found. Returning NOTFOUND.");
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

	$log->info("BEGIN: $subname");

	$mode = "NEW";
	$cfg = new Config::Simple( syntax => 'ini' );

	#Generate Main Suite Configuration
	print
"This will guide you through the generation of the config required for the management of your existing Atlassian suite. Many of the options will gather automagically however some will require manual input. This wizard will guide you through the process.\n\n";

	#Check for 64Bit Override
	if ( testOSArchitecture() eq "64" ) {
		genBooleanConfigItem(
			$mode,
			$cfg,
			"general.force32Bit",
			"Your operating system architecture has been detected as "
			  . testOSArchitecture()
			  . "bit. Do you currently use 32 bit installs (not recommended)? yes/no",
			"no"
		);
	}

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
				'^([a-zA-Z0-9\.]*)$',
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

	#Get Crowd configuration
	genBooleanConfigItem( $mode, $cfg, "crowd.enable",
		"Do you currently run Crowd on this server? yes/no ", "yes" );

	if ( $cfg->param("crowd.enable") eq "TRUE" ) {
		getExistingCrowdConfig($cfg);
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
		else {
			$log->info(
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
		$log->info(
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

	$log->info("BEGIN: $subname");

	$inputFile          = $_[0];
	$referenceVariable  = $_[1];    #such as JAVA_OPTS
	$referenceParameter = $_[2];    #such as Xmx, Xms, -XX:MaxPermSize and so on

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_inputFile",         $inputFile );
	dumpSingleVarToLog( "$subname" . "_referenceVariable", $referenceVariable );
	dumpSingleVarToLog( "$subname" . "_referenceParameter",
		$referenceParameter );

	#Try to open the provided file
	open( FILE, $inputFile )
	  or $log->logdie("Unable to open file: $inputFile");

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

			$returnValue = $result3 . $result4;
			dumpSingleVarToLog( "$subname" . " _returnValue", $returnValue );
			return $returnValue;
		}
	}
	else {
		$log->info(
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
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

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
	my $searchString;

#For each application define the file type that we are looking for in the json feed
	if ( $lcApplication eq "confluence" ) {
		$searchString = ".*Linux.*$architecture.*";
	}
	elsif ( $lcApplication eq "jira" ) {
		$searchString = ".*Linux.*$architecture.*";
	}
	elsif ( $lcApplication eq "stash" ) {
		$searchString = ".*TAR.*";
	}
	elsif ( $lcApplication eq "fisheye" ) {
		$searchString = ".*FishEye.*";
	}
	elsif ( $lcApplication eq "crowd" ) {
		$searchString = ".*TAR.*";
	}
	elsif ( $lcApplication eq "bamboo" ) {
		$searchString = ".*TAR\.GZ.*";
	}
	else {
		print
"That application ($application) is not recognised - Really you should never get here so if you managed to *wavesHi*";
		exit 2;
	}

	dumpSingleVarToLog( "$subname" . "_searchString", $searchString );

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

	$log->info("BEGIN: $subname");

	$inputFile     = $_[0];
	$lineReference = $_[1];
	$valueRegex    = $_[2];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_inputFile",     $inputFile );
	dumpSingleVarToLog( "$subname" . "_lineReference", $lineReference );
	dumpSingleVarToLog( "$subname" . "_valueRegex",    $valueRegex );
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
			$log->info("$subname: Search regex not found in line.");
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

	$log->info("BEGIN: $subname");

	$inputFile          = $_[0];
	$variableReference  = $_[1];
	$parameterReference = $_[2];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_inputFile",         $inputFile );
	dumpSingleVarToLog( "$subname" . "_variableReference", $variableReference );
	dumpSingleVarToLog( "$subname" . "_parameterReference",
		$parameterReference );
	open( FILE, $inputFile )
	  or $log->logdie("Unable to open file: $inputFile: $!");

	# read file into an array
	@data = <FILE>;

	close(FILE);

	#Search for reference line
	($index1) = grep { $data[$_] =~ /.*$parameterReference.*/ } 0 .. $#data;
	if ( !defined($index1) ) {
		$log->info(
"$subname: Line with $parameterReference not found. Returning NOTFOUND."
		);

		return "NOTFOUND";
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

	$log->info("BEGIN: $subname");
	$grep1stParam = $_[0];
	$grep2ndParam = $_[1];
	dumpSingleVarToLog( "$subname" . "_grep1stParam", $grep1stParam );
	dumpSingleVarToLog( "$subname" . "_grep2ndParam", $grep2ndParam );

	open( PIDLIST,
"/bin/ps -ef | grep $grep1stParam | grep $grep2ndParam | grep -v 'ps -ef | grep' |"
	);
	$i = 0;
	while (<PIDLIST>) {
		$line = $_;
		chomp $line;
		dumpSingleVarToLog( "$subname" . "_line_$i", $line );
		$PIDs[$i] = $line;
		$i++;
	}
	close PIDLIST;
	return @PIDs;
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
	my $configParameterName
	  ;    #the name of the config parameter the install DIR is stored in
	my $lineReference;
	my $searchFor;
	my @data;
	my $fileName;
	my $userName;
	my $cfg;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	$configParameterName = $_[0];
	$lineReference       = $_[1];
	$cfg                 = $_[2];

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_configParameterName",
		$configParameterName );
	dumpSingleVarToLog( "$subname" . "_lineReference", $lineReference );

	$fileName = $cfg->param($configParameterName) . "/bin/user.sh";

	dumpSingleVarToLog( "$subname" . "_fileName", $fileName );

	open( FILE, $fileName ) or $log->logdie("Unable to open file: $fileName.");

	# read file into an array
	@data = <FILE>;

	close(FILE);

	#Search for reference line
	my ($index1) = grep { $data[$_] =~ /^$lineReference.*/ } 0 .. $#data;

	if ( !defined($index1) ) {
		return "NOTFOUND";
	}
	else {
		if ( $data[$index1] =~ /.*=\"(.*?)\".*/ ) {
			my $result1 = $1;
			return $result1;
		}
	}
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

	$log->info("BEGIN: $subname");

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
		$fileExt = "bin";
		$filename =
		    "atlassian-confluence-" 
		  . $version . "-x"
		  . $architecture . "."
		  . $fileExt;
	}
	elsif ( $lcApplication eq "jira" ) {
		$fileExt = "bin";
		$filename =
		  "atlassian-jira-" . $version . "-x" . $architecture . "." . $fileExt;
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

	$log->info("BEGIN: $subname");

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
		$log->info(
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
		$input = getBooleanInput(
"Would you like to review the $application config before installing? Yes/No [yes]: "
		);
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
		escapeFilePath( $globalConfig->param("$lcApplication.installDir") ),
		$osUser, "" );

	#Check if user wants to remove the downloaded archive
	$input =
	  getBooleanInput( "Do you wish to delete the downloaded archive "
		  . $downloadDetails[2]
		  . "? [no]: " );
	print "\n";
	if ( $input eq "yes" ) {
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
			$log->info( "$subname: Chowning "
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
			$log->info( "$subname: Chowning "
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
	my @parameterNull;
	my $javaOptsValue;
	my $serverXMLFile;
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
	    escapeFilePath( $globalConfig->param("general.rootInstallDir") ) . "/"
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
		$input = getBooleanInput(
"Would you like to review the $application config before installing? Yes/No [yes]: "
		);
		print "\n";
		if ( $input eq "default" || $input eq "yes" ) {
			$log->info(
				"$subname: User opted to update config prior to installation."
			);
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
	generateGenericKickstart( $varfile, "INSTALL", $application );

	if (
		-d escapeFilePath( $globalConfig->param("$lcApplication.installDir") ) )
	{
		$input = getBooleanInput(
			"The current installation directory ("
			  . escapeFilePath(
				$globalConfig->param("$lcApplication.installDir")
			  )
			  . ") exists.\nIf you are sure there is not another version installed here would you like to move it to a backup? [yes]: "
		);
		print "\n";
		if ( $input eq "default" || $input eq "yes" ) {
			$log->info(
"$subname: Current install directory for $application exists, user has selected to back this up."
			);
			backupDirectoryAndChown(
				escapeFilePath(
					$globalConfig->param("$lcApplication.installDir")
				),
				"root"
			  )
			  ; #we have to use root here as due to the way Atlassian Binaries do installs there is no way to know if user exists or not.
		}
		else {
			$log->logdie(
"Cannot proceed installing $application if the directory already has an install, please remove this manually and try again.\n\n"
			);
		}
	}

	if ( -d escapeFilePath( $globalConfig->param("$lcApplication.dataDir") ) ) {
		$input =
		  getBooleanInput( "The current installation directory ("
			  . escapeFilePath( $globalConfig->param("$lcApplication.dataDir") )
			  . ") exists.\nIf you are sure there is not another version installed here would you like to move it to a backup? [yes]: "
		  );
		print "\n";
		if ( $input eq "default" || $input eq "yes" ) {
			$log->info(
"$subname: Current data directory for $application exists, user has selected to back this up."
			);
			backupDirectoryAndChown(
				escapeFilePath(
					$globalConfig->param("$lcApplication.dataDir")
				),
				"root"
			  )
			  ; #we have to use root here as due to the way Atlassian Binaries do installs there is no way to know if user exists or not.
		}
		else {
			$log->logdie(
				"Cannot proceed installing $application if the data directory ("
				  . escapeFilePath(
					$globalConfig->param("$lcApplication.dataDir")
				  )
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

	#getTheUserItWasInstalledAs - Write to config and reload
	$osUser = getUserCreatedByInstaller( $lcApplication . ".installDir",
		$configUser, $globalConfig );
	if ( $osUser eq "NOTFOUND" ) {

		#AskUserToInput
		genConfigItem(
			$mode,
			$globalConfig,
			"$lcApplication.osUser",
"Unable to detect what user $application was installed under. Please enter the OS user that $application installed itself under.",
			"",
			'^([a-zA-Z0-9]*)$',
"The user you entered was in an invalid format. Please ensure you enter only letters and numbers without any spaces or other characters.\n\n"
		);
	}
	else {
		$log->info("$subname: OS User created by installer is: $osUser");
		$globalConfig->param( $lcApplication . ".osUser", $osUser );
	}
	$log->info("Writing out config file to disk.");
	$globalConfig->write($configFile);
	loadSuiteConfig();

	#Stop the application so we can apply additional configuration
	print
"Stopping $application so that we can apply additional config. Sleeping for 60 seconds to ensure $application has completed initial startup. Please wait...\n\n";
	sleep(60);
	$log->info(
"$subname: Stopping $application so that we can apply the additional configuration options."
	);
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
"$subname: Could not stop $application successfully. Please make sure you restart manually following the end of installation"
		);
		warn
"Could not stop $application successfully. Please make sure you restart manually following the end of installation: $!\n\n";
	}

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
			$globalConfig->param( $lcApplication . ".javaParams" )
		);
	}

	#Check if user wants to remove the downloaded installer
	$input =
	  getBooleanInput( "Do you wish to delete the downloaded installer "
		  . $downloadDetails[2]
		  . "? [no]: " );
	print "\n";
	if ( $input eq "yes" ) {
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
			escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
			  . "/lib/" );

		#Chown the files again
		$log->info(
			"$subname: Chowning "
			  . escapeFilePath(
				$globalConfig->param("$lcApplication.installDir")
			  )
			  . "/lib/"
			  . " to $osUser following MySQL JDBC install."
		);
		chownRecursive( $osUser,
			escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
			  . "/lib/" );

	}

	print "Applying configuration settings to the install, please wait...\n\n";

	print "Creating backup of config files...\n\n";
	$log->info("$subname: Backing up config files.");
	backupFile(
		escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
		  . "/conf/server.xml",
		$osUser
	);

	print "Applying the configured application context...\n\n";
	$log->info( "$subname: Applying application context to "
		  . escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
		  . "/conf/server.xml" );

	updateXMLAttribute(
		escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
		  . "/conf/server.xml",
		"//////Context",
		"path",
		getConfigItem( "$lcApplication.appContext", $globalConfig )
	);

	#Update the server config with reverse proxy configuration
	$serverXMLFile =
	  escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
	  . "/conf/server.xml";
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
			updateXMLAttribute( $serverXMLFile, "///Connector", "ProxyPort",
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

	#Update config to reflect new version that is installed
	$log->info("$subname: Writing new installed version to the config file.");
	$globalConfig->param( $lcApplication . ".installedVersion", $version );
	$log->info("Writing out config file to disk.");
	$globalConfig->write($configFile);
	loadSuiteConfig();
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

	$log->info("BEGIN: $subname");

	$application   = $_[0];
	$version       = $_[1];
	$lcApplication = lc($application);

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_application", $application );
	dumpSingleVarToLog( "$subname" . "_version",     $version );

	#Set up maximum supported versions
	my $jiraSupportedVerHigh       = "5.2.6";
	my $confluenceSupportedVerHigh = "4.3.7";
	my $crowdSupportedVerHigh      = "2.6.0";
	my $fisheyeSupportedVerHigh    = "2.10.1";
	my $bambooSupportedVerHigh     = "4.4.3";
	my $stashSupportedVerHigh      = "2.1.2";

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
		$log->info(
"$subname: Version provided ($version) of $application is supported (max supported version is $productVersion)."
		);
		return "yes";
	}
	else {
		$log->info(
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
}

########################################
#Manage Service                        #
########################################
sub manageService {
	my $application;
	my $lcApplication;
	my $mode;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

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
			  or $log->logdie("Adding $application as a service failed: $?");
		}
		elsif ( $distro eq "debian" ) {
			system("update-rc.d $lcApplication defaults") == 0
			  or $log->logdie("Adding $application as a service failed: $?");
		}
		print "Service installed successfully...\n\n";
	}

	#Remove the service
	elsif ( $mode eq "UNINSTALL" ) {
		$log->info("Removing Service for $application.");
		print "Removing Service for $application...\n\n";
		if ( $distro eq "redhat" ) {
			system("chkconfig --del $lcApplication") == 0
			  or $log->logdie("Removing $application as a service failed: $?");
		}
		elsif ( $distro eq "debian" ) {
			system("update-rc.d -f $lcApplication remove") == 0
			  or $log->logdie("Removing $application as a service failed: $?");

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
			print "\n"
			  . "$application can now be accessed on http://localhost:"
			  . $globalConfig->param("$lcApplication.connectorPort")
			  . getConfigItem( "$lcApplication.appContext", $globalConfig )
			  . ".\n\n";
		}
		else {
			print
"\n The service could not be started correctly please ensure you do this manually.\n\n";
		}
	}

	print
"The $application install has completed. Please press enter to return to the main menu.";
	$input = <STDIN>;
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

	$input = getBooleanInput(
		"Do you wish to start the $application service? yes/no [yes]: ");
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
		if ( $processReturnCode eq "FAIL" | $processReturnCode eq "WARN" ) {
			warn
"Could not start $application successfully. Please make sure to do this manually as the service is currently stopped: $!\n\n";
		}
		print "\n\n";
	}

	print
"The $application install has completed. Please press enter to return to the main menu";
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
			print "\n"
			  . "$application can now be accessed on http://localhost:"
			  . $globalConfig->param("$lcApplication.connectorPort")
			  . getConfigItem( "$lcApplication.appContext", $globalConfig )
			  . ".\n\n";
		}
		else {
			print
"\n The service could not be started correctly please ensure you do this manually.\n\n";
		}
	}

	print
"The $application upgrade has completed. Please press enter to return to the main menu.";
	$input = <STDIN>;
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

	$log->info("BEGIN: $subname");
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

	$log->info("BEGIN: $subname");
	$application   = $_[0];
	$lcApplication = lc($application);
	$grep1stParam  = $_[1];
	$grep2ndParam  = $_[2];
	dumpSingleVarToLog( "$subname" . "_application",  $application );
	dumpSingleVarToLog( "$subname" . "_grep1stParam", $grep1stParam );
	dumpSingleVarToLog( "$subname" . "_grep2ndParam", $grep2ndParam );

	#first make sure service is not already started
	@pidList = getPIDList( $grep1stParam, $grep2ndParam );

	if ( $lcApplication eq 'jira' or $lcApplication eq 'confluence' ) {
		$serviceName = $globalConfig->param( $lcApplication . ".osUser" );
	}
	else {
		$serviceName = $lcApplication;
	}

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

	$log->info("BEGIN: $subname");
	$application   = $_[0];
	$lcApplication = lc($application);
	$grep1stParam  = $_[1];
	$grep2ndParam  = $_[2];
	dumpSingleVarToLog( "$subname" . "_application",  $application );
	dumpSingleVarToLog( "$subname" . "_grep1stParam", $grep1stParam );
	dumpSingleVarToLog( "$subname" . "_grep2ndParam", $grep2ndParam );

	if ( $lcApplication eq 'jira' or $lcApplication eq 'confluence' ) {
		$serviceName = $globalConfig->param( $lcApplication . ".osUser" );
	}
	else {
		$serviceName = $lcApplication;
	}

	while ( $LOOP == 1 ) {

		#first make sure the service is actually running
		@pidList = getPIDList( $grep1stParam, $grep2ndParam );

		if ( @pidList == 0 ) {

			#Service is not running... no need to stop it
			$log->info(
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
			system( "service " . $serviceName . " stop" );
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
						elsif ( ( lc $input ) eq "try" || ( lc $input ) eq "t" )
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
	open( FILE, $inputFile )
	  or $log->logdie("Unable to open file: $inputFile");

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
	open( FILE, $inputFile )
	  or $log->logdie("Unable to open file: $inputFile");

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

#If no javaOpts parameters defined we get an undefined variable. This accounts for that.
	if ( !defined $javaOpts ) {
		$javaOpts = "";
	}

	#LogInputParams if in Debugging Mode
	dumpSingleVarToLog( "$subname" . "_inputFile", $inputFile );
	dumpSingleVarToLog( "$subname" . "_javaOpts",  $javaOpts );

	#Try to open the provided file
	open( FILE, $inputFile )
	  or $log->logdie("Unable to open file: $inputFile");

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
#updateXMLTextValue                    #
########################################
sub updateXMLTextValue {

	my $xmlFile;    #Must Be Absolute Path
	my $searchString;
	my $attributeValue;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

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
		$log->info(
"$subname: Found $searchString in $xmlFile. Setting element to $attributeValue"
		);

		#Set the node to the new attribute value
		$node->set_text($attributeValue);
	}

	#Print the new XML tree back to the original file
	$log->info("$subname: Writing out updated xmlFile: $xmlFile.");
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
		my $newLine = $variableReference . $count . "=" . $newValue . "\n";
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
#Uninstall Generic                     #
########################################
sub uninstallGeneric {
	my $application;
	my $initdFile;
	my $input;
	my $subname = ( caller(0) )[3];
	my $lcApplication;
	my $processReturnCode;

	$log->info("BEGIN: $subname");

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
	$input = getBooleanInput("Do you really want to continue? yes/no [no]: ");
	print "\n";
	if ( $input eq "yes" ) {

		system(
			escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
			  . "/uninstall -q" );
		if ( $? == -1 ) {
			$log->logdie(
"$application uninstall did not complete successfully. Please check the logs and complete manually: $!\n"
			);
		}

		#Check if you REALLY want to remove data directory
		$input = getBooleanInput(
"We will now remove the data directory ($application home directory). Are you REALLY REALLY REALLY (REALLY) sure you want to do this? (not recommended) yes/no [no]: \n"
		);
		print "\n";
		if ( $input eq "yes" ) {
			rmtree(
				[
					escapeFilePath(
						$globalConfig->param("$lcApplication.dataDir")
					)
				]
			);
		}
		else {
			print
"The data directory has not been deleted and is still available at "
			  . escapeFilePath( $globalConfig->param("$lcApplication.dataDir") )
			  . ".\n\n";
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
#UpgradeGeneric                        #
########################################
sub upgradeGeneric {
	my $input;
	my $mode;
	my $version;
	my $application;
	my $lcApplication;
	my @downloadDetails;
	my @downloadVersionCheck;
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
	my $tomcatDir;
	my $webappDir;
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

		$input = getBooleanInput(
"Would you like to review the $application config before upgrading? Yes/No [yes]: "
		);
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

	#Get the user the application will run as
	$osUser = $globalConfig->param("$lcApplication.osUser");

	#Check the user exists or create if not
	createOSUser($osUser);

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
		@downloadVersionCheck =
		  getLatestDownloadURL( $lcApplication, $globalArch );
		my $versionSupported = compareTwoVersions(
			$globalConfig->param("$lcApplication.installedVersion"),
			$downloadVersionCheck[1] );
		if ( $versionSupported eq "GREATER" ) {
			$log->logdie( "The version of $application to be downloaded ("
				  . $downloadVersionCheck[1]
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
	elsif ( $mode eq "SPECIFIC" ) {
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

	#Prompt user to stop existing service
	$log->info("$subname: Stopping existing $application service...");
	print
"We will now stop the existing $application service, please press enter to continue...";
	$input = <STDIN>;
	print "\n";
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
	extractAndMoveDownload( $downloadDetails[2],
		escapeFilePath( $globalConfig->param("$lcApplication.installDir") ),
		$osUser, "UPGRADE" );

	#Check if user wants to remove the downloaded archive
	$input =
	  getBooleanInput( "Do you wish to delete the downloaded archive "
		  . $downloadDetails[2]
		  . "? [no]: " );
	print "\n";
	if ( $input eq "yes" ) {
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
			$log->info(
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
			$log->info(
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
	$log->info(
		"$subname: Checking for and chowning $application home directory.");
	print "Checking if data directory exists and re-chowning it...\n\n";
	createAndChownDirectory(
		escapeFilePath( $globalConfig->param("$lcApplication.dataDir") ),
		$osUser );

	#GenericUpgradeCompleted
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
	my @parameterNull2;
	my $javaOptsValue;
	my $varfile;
	my @requiredConfigItems;
	my $downloadArchivesUrl;
	my $configUser;
	my $lcApplication;
	my $serverXMLFile;
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
	    escapeFilePath( $globalConfig->param("general.rootInstallDir") ) . "/"
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
		$input = getBooleanInput(
"Would you like to review the $application config before upgrading? Yes/No [yes]: "
		);
		print "\n";
		if ( $input eq "default" || $input eq "yes" ) {
			$log->info(
				"$subname: User opted to update config prior to installation."
			);
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

	#We are upgrading, get the latest version
	$input = getBooleanInput(
		"Would you like to upgrade to the latest version? yes/no [yes]: ");
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
	generateGenericKickstart( $varfile, "UPGRADE", $application );

	#upgrade
	$log->info(
		"$subname: Running " . $downloadDetails[2] . " -q -varfile $varfile" );
	system( $downloadDetails[2] . " -q -varfile $varfile" );
	if ( $? == -1 ) {
		$log->logdie(
"$application upgrade did not complete successfully. Please check the install logs and try again: $!\n"
		);
	}

	#getTheUserItWasInstalledAs - Write to config and reload
	$osUser =
	  getUserCreatedByInstaller( "$lcApplication.installDir", $configUser,
		$globalConfig );
	if ( $osUser eq "NOTFOUND" ) {

		#AskUserToInput
		genConfigItem(
			$mode,
			$globalConfig,
			"$lcApplication.osUser",
"Unable to detect what user $application was installed under. Please enter the OS user that $application installed itself under.",
			"",
			'^([a-zA-Z0-9]*)$',
"The user you entered was in an invalid format. Please ensure you enter only letters and numbers without any spaces or other characters.\n\n"
		);
	}
	else {
		$log->info("$subname: OS User created by installer is: $osUser");
		$globalConfig->param( $lcApplication . ".osUser", $osUser );
	}
	$log->info("Writing out config file to disk.");
	$globalConfig->write($configFile);
	loadSuiteConfig();

	#Stop the application so we can apply additional configuration
	$log->info(
"$subname: Stopping $application so that we can apply the additional configuration options."
	);
	print
"Stopping $application so that we can apply additional config. Sleeping for 60 seconds to ensure $application has completed initial startup. Please wait...\n\n";
	sleep(60);
	if (
		my $processReturnCode = stopService(
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

	#Check if user wants to remove the downloaded installer
	$input =
	  getBooleanInput( "Do you wish to delete the downloaded installer "
		  . $downloadDetails[2]
		  . "? [no]: " );
	print "\n";
	if ( $input eq "yes" ) {
		$log->info("$subname: User opted to delete downloaded installer.");
		unlink $downloadDetails[2]
		  or warn "Could not delete " . $downloadDetails[2] . ": $!";
	}

	@parameterNull2 = $globalConfig->param("$lcApplication.javaParams");
	if (   ( $#parameterNull2 == -1 )
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
			$globalConfig->param( $lcApplication . ".javaParams" )
		);
	}

#If MySQL is the Database, Atlassian apps do not come with the driver so copy it

	if ( $globalConfig->param("general.targetDBType") eq "MySQL" ) {
		print
"Database is configured as MySQL, copying the JDBC connector to $application install.\n\n";
		$log->info(
"$subname: Copying MySQL JDBC connector to $application install directory."
		);
		copyFile( $globalConfig->param("general.dbJDBCJar"),
			escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
			  . "/lib/" );

		#Chown the files again
		$log->info(
			"$subname: Chowning "
			  . escapeFilePath(
				$globalConfig->param("$lcApplication.installDir")
			  )
			  . "/lib/"
		);
		chownRecursive( $osUser,
			escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
			  . "/lib/" );
	}

	print "Applying configuration settings to the install, please wait...\n\n";

	print "Creating backup of config files...\n\n";
	$log->info("$subname: Backing up config files.");

	backupFile(
		escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
		  . "/conf/server.xml",
		$osUser
	);

	print "Applying the configured application context...\n\n";
	$log->info( "$subname: Applying application context to "
		  . escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
		  . "/conf/server.xml" );

	#Update the server config with reverse proxy configuration
	$serverXMLFile =
	  escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
	  . "/conf/server.xml";
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

	#Update the server config with the configured connector port
	updateXMLAttribute(
		escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
		  . "/conf/server.xml",
		"//////Context",
		"path",
		getConfigItem( "$lcApplication.appContext", $globalConfig )
	);
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

		displayInitialConfigMenu();
	}

 #If config file exists check for required config items.
 #Useful if new functions have been added to ensure new config items are defined
	else {
		@requiredConfigItems = (
			"general.rootDataDir",  "general.rootInstallDir",
			"general.targetDBType", "general.force32Bit",
			"general.apacheProxy"
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
#Display Inital Config Menu            #
########################################
sub displayInitialConfigMenu {
	my $choice;
	my $menuText;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	my $LOOP = 1;
	while ( $LOOP == 1 ) {

		# define the main menu as a multiline string
		$menuText = <<'END_TXT';

      Welcome to the Atlassian Suite Manager Script

      AtlassianSuiteManager Copyright (C) 2012-2013  Stuart Ryan
      
      This program comes with ABSOLUTELY NO WARRANTY;
      This is free software, and you are welcome to redistribute it
      under certain conditions; read the COPYING file included for details.

      ************************
      * Initial Config Menu  *
      ************************
      
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
			exit 0;
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

	$log->info("BEGIN: $subname");

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
		$menuText = <<'END_TXT';

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

      *********************
      * ASM Install Menu  *
      *********************
      
      Please select from the following options:

END_TXT

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

      ******************
      * ASM Main Menu  *
      ******************
      
      Please select from the following options:

      1) Install a new application
      2) Upgrade an existing application
      3) Uninstall an application
      D) Download the full latest version of the Atlassian Suite (Testing & Debugging)
      G) Generate Suite Config
      T) Testing Function (varies)
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
		elsif ( lc($choice) eq "g\n" ) {
			system 'clear';
			generateSuiteConfig();
		}
		elsif ( lc($choice) eq "d\n" ) {
			system 'clear';
			downloadLatestAtlassianSuite($globalArch);
		}
		elsif ( lc($choice) eq "t\n" ) {
			system 'clear';
			testXMLAttribute(
				"/opt/atlassian/bamboo/webapp/WEB-INF/classes/jetty.xml");
			my $test = <STDIN>;
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

	$log->info("BEGIN: $subname");

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
		$menuText = <<'END_TXT';

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

      ***********************
      * ASM Uninstall Menu  *
      ***********************
      
      Please select from the following options:

END_TXT

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

	$log->info("BEGIN: $subname");

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
		$menuText = <<'END_TXT';

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

      *********************
      * ASM Upgrade Menu  *
      *********************
      
END_TXT

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
			}
			else {
				upgradeBamboo();
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
			}
			else {
				upgradeConfluence();
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
			}
			else {
				upgradeCrowd();
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
			}
			else {
				upgradeFisheye();
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
			}
			else {
				upgradeJira();
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
			}
			else {
				upgradeStash();
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
	my $input;
	my $LOOP = 0;
	my $returnValue;

	$log->info("BEGIN: $subname");

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
"Enter any additional paramaters currently add to the JAVA RUN_OPTS for your $application install. Just press enter if you have none.",
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
			'^([a-zA-Z0-9\.]*)$',
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

	$serverConfigFile =
	  escapeFilePath( $cfg->param("$lcApplication.installDir") )
	  . "/conf/wrapper.conf";

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
			"$subname: $application data directory found and added to config.");
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

	$returnValue = "";

	#getOSuser
	open( WORKING_DIR_HANDLE,
		escapeFilePath( $cfg->param("$lcApplication.installDir") ) )
	  or $log->logdie(
"Unable to open install dir for $application to test who owns it. Really this should never happen as we have already tested that the directory exists."
	  );
	my (
		$dev,   $ino,     $fileMode, $nlink, $uid,
		$gid,   $rdev,    $size,     $atime, $mtime,
		$ctime, $blksize, $blocks
	) = stat(WORKING_DIR_HANDLE);
	$returnValue = getpwuid($uid);

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

	#Set up some defaults for Bamboo
	$cfg->param( "bamboo.tomcatDir", "" )
	  ;    #we leave these blank deliberately due to the way Bamboo works
	$cfg->param( "bamboo.webappDir", "" )
	  ;    #we leave these blank deliberately due to the way Bamboo works
	$cfg->param( "bamboo.processSearchParameter1", "java" );
	$cfg->param(
		"bamboo.processSearchParameter2",
		"com.atlassian.bamboo.server.Server"
	);
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
	checkConfiguredPort( "bamboo.connectorPort", $cfg );

	genConfigItem(
		$mode,
		$cfg,
		"bamboo.javaParams",
"Enter any additional paramaters you would like to add to the Java RUN_OPTS.",
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
			'^([a-zA-Z0-9\.]*)$',
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

	#Set up some defaults for Bamboo
	$cfg->param( "bamboo.tomcatDir", "" )
	  ;    #we leave these blank deliberately due to the way Bamboo works
	$cfg->param( "bamboo.webappDir", "" )
	  ;    #we leave these blank deliberately due to the way Bamboo works
	$cfg->param( "bamboo.processSearchParameter1", "java" );
	$cfg->param(
		"bamboo.processSearchParameter2",
		"com.atlassian.bamboo.server.Server"
	);

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
	my @parameterNull;
	my $javaOptsValue;
	my $WrapperDownloadFile;
	my $WrapperDownloadUrlFor64Bit =
"https://confluence.atlassian.com/download/attachments/289276785/Bamboo_64_Bit_Wrapper.zip?version=1&modificationDate=1346435557878&api=v2";
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	#Set up list of config items that are requred for this install to run
	$lcApplication       = lc($application);
	@requiredConfigItems = (
		"bamboo.appContext",              "bamboo.enable",
		"bamboo.dataDir",                 "bamboo.installDir",
		"bamboo.runAsService",            "bamboo.osUser",
		"bamboo.connectorPort",           "bamboo.javaMinMemory",
		"bamboo.javaMaxMemory",           "bamboo.javaMaxPermSize",
		"bamboo.processSearchParameter1", "bamboo.processSearchParameter2"
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

	#Run generic installer steps
	installGeneric( $application, $downloadArchivesUrl, \@requiredConfigItems );
	$osUser = $globalConfig->param("$lcApplication.osUser")
	  ; #we get this after install in CASE the installer changes the configured user in future

	#Perform application specific configuration
	print "Applying configuration settings to the install, please wait...\n\n";

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
	$log->info( "$subname: Applying homedir in "
		  . escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
		  . "/webapp/WEB-INF/classes/bamboo-init.properties" );
	print "Applying home directory to config...\n\n";
	updateLineInFile(
		escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
		  . "/webapp/WEB-INF/classes/bamboo-init.properties",
		"bamboo.home",
		"$lcApplication.home="
		  . escapeFilePath( $globalConfig->param("$lcApplication.dataDir") ),
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

		updateLineInFile(
			$serverConfigFile,                    "wrapper.app.parameter.3",
			"#wrapper.app.parameter.3=../webapp", "wrapper.app.parameter.3"
		);

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
			escapeFilePath( $globalConfig->param("$lcApplication.installDir") ),
			$WrapperDownloadUrlFor64Bit, $osUser
		);

		rmtree(
			[
				escapeFilePath(
					$globalConfig->param("$lcApplication.installDir")
				  )
				  . "/wrapper"
			]
		);

		extractAndMoveDownload(
			$WrapperDownloadFile,
			escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
			  . "/wrapper",
			$osUser,
			""
		);
	}

	#Generate the init.d file
	print
"Setting up initd files and run as a service (if configured) please wait...\n\n";
	$log->info("$subname: Generating init.d file for $application.");

	generateInitD(
		$lcApplication, $osUser,
		escapeFilePath( $globalConfig->param("$lcApplication.installDir") ),
		"bamboo.sh start",
		"bamboo.sh stop"
	);

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
	my $WrapperDownloadUrlFor64Bit =
"https://confluence.atlassian.com/download/attachments/289276785/Bamboo_64_Bit_Wrapper.zip?version=1&modificationDate=1346435557878&api=v2";
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	#Set up list of config items that are requred for this install to run
	$lcApplication       = lc($application);
	@requiredConfigItems = (
		"bamboo.appContext",              "bamboo.enable",
		"bamboo.dataDir",                 "bamboo.installDir",
		"bamboo.runAsService",            "bamboo.osUser",
		"bamboo.connectorPort",           "bamboo.javaMinMemory",
		"bamboo.javaMaxMemory",           "bamboo.javaMaxPermSize",
		"bamboo.processSearchParameter1", "bamboo.processSearchParameter2"
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

	#Run generic installer steps
	upgradeGeneric( $application, $downloadArchivesUrl, \@requiredConfigItems );
	$osUser = $globalConfig->param("$lcApplication.osUser")
	  ; #we get this after install in CASE the installer changes the configured user in future

	#Perform application specific configuration
	print "Applying configuration settings to the install, please wait...\n\n";

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

		updateLineInFile(
			$serverConfigFile,                    "wrapper.app.parameter.3",
			"#wrapper.app.parameter.3=../webapp", "wrapper.app.parameter.3"
		);

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
	}

	#Edit Bamboo config file to reference homedir
	$log->info( "$subname: Applying homedir in "
		  . escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
		  . "/webapp/WEB-INF/classes/bamboo-init.properties" );
	print "Applying home directory to config...\n\n";
	updateLineInFile(
		escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
		  . "/webapp/WEB-INF/classes/bamboo-init.properties",
		"bamboo.home",
		"$lcApplication.home="
		  . escapeFilePath( $globalConfig->param("$lcApplication.dataDir") ),
		"#bamboo.home=C:/bamboo/bamboo-home"
	);

	print "Applying Java memory configuration to install...\n\n";
	$log->info( "$subname: Applying Java memory parameters to "
		  . $javaMemParameterFile );
	print "Applying Apache proxy parameters to config...\n\n";

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
	if ( ( $#parameterNull == -1 )
		|| $globalConfig->param("$lcApplication.javaParams") eq "" )
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
			escapeFilePath( $globalConfig->param("$lcApplication.installDir") ),
			$WrapperDownloadUrlFor64Bit, $osUser
		);

		rmtree(
			[
				escapeFilePath(
					$globalConfig->param("$lcApplication.installDir")
				  )
				  . "/wrapper"
			]
		);

		extractAndMoveDownload(
			$WrapperDownloadFile,
			escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
			  . "/wrapper",
			$osUser,
			""
		);
	}

	#Generate the init.d file
	print
"Setting up initd files and run as a service (if configured) please wait...\n\n";
	$log->info("$subname: Generating init.d file for $application.");

	generateInitD(
		$lcApplication, $osUser,
		escapeFilePath( $globalConfig->param("$lcApplication.installDir") ),
		"bamboo.sh start",
		"bamboo.sh stop"
	);

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
	my $input;
	my $LOOP  = 0;
	my $LOOP2 = 0;
	my $returnValue;

	$log->info("BEGIN: $subname");

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
"Enter any additional paramaters currently add to the JAVA RUN_OPTS for your $application install. Just press enter if you have none.",
		"",
		"",
		""
	);

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
			"$subname: $application data directory found and added to config.");
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
	$returnValue =
	  getUserCreatedByInstaller( "$lcApplication.installDir", "CONF_USER",
		$cfg );

	if ( $returnValue eq "NOTFOUND" ) {

		#AskUserToInput
		genConfigItem(
			$mode,
			$cfg,
			"$lcApplication.osUser",
"Unable to detect what user $application was installed under. Please enter the OS user that $application runs as.",
			"",
			'^([a-zA-Z0-9]*)$',
"The user you entered was in an invalid format. Please ensure you enter only letters and numbers without any spaces or other characters.\n\n"
		);
	}
	else {

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
				'^([a-zA-Z0-9\.]*)$',
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
			$cfg->param( "$lcApplication.apacheProxySSL", $returnValue );
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
	checkConfiguredPort( "confluence.connectorPort", $cfg );

	genConfigItem(
		$mode,
		$cfg,
		"confluence.serverPort",
"Please enter the SERVER port Confluence will run on (note this is the control port not the port you access in a browser).",
		"8000",
		'^([0-9]*)$',
"The port number you entered contained invalid characters. Please ensure you enter only digits.\n\n"
	);

	checkConfiguredPort( "confluence.serverPort", $cfg );

	genConfigItem(
		$mode,
		$cfg,
		"confluence.javaParams",
"Enter any additional paramaters you would like to add to the Java RUN_OPTS.",
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
			'^([a-zA-Z0-9\.]*)$',
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
		"confluence.processSearchParameter2"
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
	installGenericAtlassianBinary(
		$application, $downloadArchivesUrl,
		"CONF_USER",  \@requiredConfigItems
	);

	$osUser = $globalConfig->param("$lcApplication.osUser");

	$javaMemParameterFile =
	  escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
	  . "/bin/setenv.sh";
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
		"confluence.processSearchParameter2"
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

	upgradeGenericAtlassianBinary(
		$application, $downloadArchivesUrl,
		"CONF_USER",  \@requiredConfigItems
	);

	$osUser = $globalConfig->param("$lcApplication.osUser");

	$javaMemParameterFile =
	  escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
	  . "/bin/setenv.sh";
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

	$log->info("BEGIN: $subname");

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
"Enter any additional paramaters currently add to the JAVA RUN_OPTS for your $application install. Just press enter if you have none.",
		"",
		"",
		""
	);

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
			"$subname: $application data directory found and added to config.");
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
			"/jira",
			'(?!^.*/$)^(/.*)',
"The input you entered was not in the valid format of '/folder'. Please ensure you enter the path with a "
			  . "leading '/' and NO trailing '/'.\n\n"
		);
	}
	else {
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
	open( WORKING_DIR_HANDLE,
		escapeFilePath( $cfg->param("$lcApplication.installDir") ) )
	  or $log->logdie(
"Unable to open install dir for $application to test who owns it. Really this should never happen as we have already tested that the directory exists."
	  );
	my (
		$dev,   $ino,     $fileMode, $nlink, $uid,
		$gid,   $rdev,    $size,     $atime, $mtime,
		$ctime, $blksize, $blocks
	) = stat(WORKING_DIR_HANDLE);
	$returnValue = getpwuid($uid);

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
				'^([a-zA-Z0-9\.]*)$',
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
			$cfg->param( "$lcApplication.apacheProxySSL", $returnValue );
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
	$cfg->param( "$lcApplication.tomcatDir",               "/apache-tomcat" );
	$cfg->param( "$lcApplication.webappDir",               "/crowd-webapp" );
	$cfg->param( "$lcApplication.processSearchParameter1", "java" );
	$cfg->param( "$lcApplication.processSearchParameter2",
		    "Dcatalina.base="
		  . $cfg->param("$lcApplication.installDir")
		  . $cfg->param("$lcApplication.tomcatDir") );
	$cfg->param( "$lcApplication.enable", "TRUE" );

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
	checkConfiguredPort( "crowd.connectorPort", $cfg );

	genConfigItem(
		$mode,
		$cfg,
		"crowd.serverPort",
"Please enter the SERVER port Crowd will run on (note this is the control port not the port you access in a browser).",
		"8001",
		'^([0-9]*)$',
"The port number you entered contained invalid characters. Please ensure you enter only digits.\n\n"
	);
	checkConfiguredPort( "crowd.serverPort", $cfg );

	genConfigItem(
		$mode,
		$cfg,
		"crowd.javaParams",
"Enter any additional paramaters you would like to add to the Java RUN_OPTS.",
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
			'^([a-zA-Z0-9\.]*)$',
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
		    "Dcatalina.base="
		  . $cfg->param("crowd.installDir")
		  . $cfg->param("crowd.tomcatDir") );

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
	my @requiredConfigItems;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

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

   #Apply application context
   #$log->info( "$subname: Applying application context to " . $serverXMLFile );
   #print "Applying application context to config...\n\n";
   #updateXMLAttribute( $serverXMLFile, "//////Context", "path",
   #	getConfigItem( "$lcApplication.appContext", $globalConfig ) );

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
			$globalConfig->param( $lcApplication . ".javaParams" )
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

	generateInitD( $lcApplication, $osUser,
		escapeFilePath( $globalConfig->param("$lcApplication.installDir") ),
		"start_crowd.sh", "stop_crowd.sh" );

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
	my @requiredConfigItems;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

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
			$globalConfig->param( $lcApplication . ".javaParams" )
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
	generateInitD( $lcApplication, $osUser,
		escapeFilePath( $globalConfig->param("$lcApplication.installDir") ),
		"start_crowd.sh", "stop_crowd.sh" );

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
	my $input;
	my $LOOP = 0;
	my $returnValue;

	$log->info("BEGIN: $subname");

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
"Enter any additional paramaters currently add to the JAVA RUN_OPTS for your $application install. Just press enter if you have none.",
		"",
		"",
		""
	);

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

	print
"Please wait, attempting to get the $application data/home directory from it's config files...\n\n";
	$log->info(
"$subname: Attempting to get $application data directory from config file $serverConfigFile."
	);

	#get data/home directory
	$returnValue = getEnvironmentVars( "/etc/environment", "FISHEYE_INST" );

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
			"$subname: $application connectorPort found and added to config." );
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
	open( WORKING_DIR_HANDLE,
		escapeFilePath( $cfg->param("$lcApplication.installDir") ) )
	  or $log->logdie(
"Unable to open install dir for $application to test who owns it. Really this should never happen as we have already tested that the directory exists."
	  );
	my (
		$dev,   $ino,     $fileMode, $nlink, $uid,
		$gid,   $rdev,    $size,     $atime, $mtime,
		$ctime, $blksize, $blocks
	) = stat(WORKING_DIR_HANDLE);
	$returnValue = getpwuid($uid);

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
				'^([a-zA-Z0-9\.]*)$',
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
			$cfg->param( "$lcApplication.apacheProxySSL", $returnValue );
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
	checkConfiguredPort( "fisheye.connectorPort", $cfg );

	genConfigItem(
		$mode,
		$cfg,
		"fisheye.serverPort",
"Please enter the SERVER port Fisheye will run on (note this is the control port not the port you access in a browser).",
		"8059",
		'^([0-9]*)$',
"The port number you entered contained invalid characters. Please ensure you enter only digits.\n\n"
	);
	checkConfiguredPort( "fisheye.serverPort", $cfg );

	genConfigItem(
		$mode,
		$cfg,
		"fisheye.javaParams",
"Enter any additional paramaters you would like to add to the Java RUN_OPTS.",
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
			'^([a-zA-Z0-9\.]*)$',
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

	$log->info("BEGIN: $subname");

	#Set up list of config items that are requred for this install to run
	$lcApplication       = lc($application);
	@requiredConfigItems = (
		"fisheye.appContext",      "fisheye.enable",
		"fisheye.dataDir",         "fisheye.installDir",
		"fisheye.runAsService",    "fisheye.osUser",
		"fisheye.serverPort",      "fisheye.connectorPort",
		"fisheye.javaMinMemory",   "fisheye.javaMaxMemory",
		"fisheye.javaMaxPermSize", "fisheye.processSearchParameter1",
		"fisheye.processSearchParameter2"
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
			$globalConfig->param( $lcApplication . ".javaParams" )
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
		$lcApplication,
		$osUser,
		escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
		  . "/bin/",
		"start.sh",
		"stop.sh"
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

	$log->info("BEGIN: $subname");

	#Set up list of config items that are requred for this install to run
	$lcApplication       = lc($application);
	@requiredConfigItems = (
		"fisheye.appContext",      "fisheye.enable",
		"fisheye.dataDir",         "fisheye.installDir",
		"fisheye.runAsService",    "fisheye.osUser",
		"fisheye.serverPort",      "fisheye.connectorPort",
		"fisheye.javaMinMemory",   "fisheye.javaMaxMemory",
		"fisheye.javaMaxPermSize", "fisheye.processSearchParameter1",
		"fisheye.processSearchParameter2"
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
			$globalConfig->param( $lcApplication . ".javaParams" )
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
		$lcApplication,
		$osUser,
		escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
		  . "/bin/",
		"start.sh",
		"stop.sh"
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
	my $input;
	my $LOOP = 0;
	my $returnValue;

	$log->info("BEGIN: $subname");

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
"Enter any additional paramaters currently add to the JAVA RUN_OPTS for your $application install. Just press enter if you have none.",
		"",
		"",
		""
	);

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
			"$subname: $application connectorPort found and added to config." );
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
	$returnValue =
	  getUserCreatedByInstaller( "$lcApplication.installDir", "JIRA_USER",
		$cfg );

	if ( $returnValue eq "NOTFOUND" ) {

		#AskUserToInput
		genConfigItem(
			$mode,
			$cfg,
			"$lcApplication.osUser",
"Unable to detect what user $application was installed under. Please enter the OS user that $application runs as.",
			"",
			'^([a-zA-Z0-9]*)$',
"The user you entered was in an invalid format. Please ensure you enter only letters and numbers without any spaces or other characters.\n\n"
		);
	}
	else {

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
				'^([a-zA-Z0-9\.]*)$',
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
			$cfg->param( "$lcApplication.apacheProxySSL", $returnValue );
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
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");
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

	checkConfiguredPort( "jira.connectorPort", $cfg );

	genConfigItem(
		$mode,
		$cfg,
		"jira.serverPort",
"Please enter the SERVER port Jira will run on (note this is the control port not the port you access in a browser).",
		"8003",
		'^([0-9]*)$',
"The port number you entered contained invalid characters. Please ensure you enter only digits.\n\n"
	);

	checkConfiguredPort( "jira.serverPort", $cfg );

	genConfigItem(
		$mode,
		$cfg,
		"jira.javaParams",
"Enter any additional paramaters you would like to add to the Java RUN_OPTS.",
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
			'^([a-zA-Z0-9\.]*)$',
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
		"jira.appContext",              "jira.enable",
		"jira.dataDir",                 "jira.installDir",
		"jira.runAsService",            "jira.serverPort",
		"jira.connectorPort",           "jira.javaMinMemory",
		"jira.javaMaxMemory",           "jira.javaMaxPermSize",
		"jira.processSearchParameter1", "jira.processSearchParameter2"
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
	installGenericAtlassianBinary(
		$application, $downloadArchivesUrl,
		"JIRA_USER",  \@requiredConfigItems
	);

	$osUser = $globalConfig->param("$lcApplication.osUser");

	$javaMemParameterFile =
	  escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
	  . "/bin/setenv.sh";

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
		"jira.appContext",              "jira.enable",
		"jira.dataDir",                 "jira.installDir",
		"jira.runAsService",            "jira.serverPort",
		"jira.connectorPort",           "jira.javaMinMemory",
		"jira.javaMaxMemory",           "jira.javaMaxPermSize",
		"jira.processSearchParameter1", "jira.processSearchParameter2"
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

	upgradeGenericAtlassianBinary(
		$application, $downloadArchivesUrl,
		"JIRA_USER",  \@requiredConfigItems
	);

	$osUser = $globalConfig->param("$lcApplication.osUser");

	$javaMemParameterFile =
	  escapeFilePath( $globalConfig->param("$lcApplication.installDir") )
	  . "/bin/setenv.sh";

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
	my $input;
	my $LOOP = 0;
	my $returnValue;

	$log->info("BEGIN: $subname");

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
"Enter any additional paramaters currently add to the JAVA RUN_OPTS for your $application install. Just press enter if you have none.",
		"",
		"",
		""
	);

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
			"$subname: $application connectorPort found and added to config." );
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
	open( WORKING_DIR_HANDLE,
		escapeFilePath( $cfg->param("$lcApplication.installDir") ) )
	  or $log->logdie(
"Unable to open install dir for $application to test who owns it. Really this should never happen as we have already tested that the directory exists."
	  );
	my (
		$dev,   $ino,     $fileMode, $nlink, $uid,
		$gid,   $rdev,    $size,     $atime, $mtime,
		$ctime, $blksize, $blocks
	) = stat(WORKING_DIR_HANDLE);
	$returnValue = getpwuid($uid);

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
				'^([a-zA-Z0-9\.]*)$',
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
			$cfg->param( "$lcApplication.apacheProxySSL", $returnValue );
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
		"8085",
		'^([0-9]*)$',
"The port number you entered contained invalid characters. Please ensure you enter only digits.\n\n"
	);
	checkConfiguredPort( "stash.connectorPort", $cfg );

	genConfigItem(
		$mode,
		$cfg,
		"stash.serverPort",
"Please enter the SERVER port Stash will run on (note this is the control port not the port you access in a browser).",
		"8004",
		'^([0-9]*)$',
"The port number you entered contained invalid characters. Please ensure you enter only digits.\n\n"
	);

	checkConfiguredPort( "stash.serverPort", $cfg );

	genConfigItem(
		$mode,
		$cfg,
		"stash.javaParams",
"Enter any additional paramaters you would like to add to the Java RUN_OPTS.",
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
			'^([a-zA-Z0-9\.]*)$',
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
	my @requiredConfigItems;
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	#Set up list of config items that are requred for this install to run
	$lcApplication       = lc($application);
	@requiredConfigItems = (
		"stash.appContext",              "stash.enable",
		"stash.dataDir",                 "stash.installDir",
		"stash.runAsService",            "stash.serverPort",
		"stash.connectorPort",           "stash.osUser",
		"stash.webappDir",               "stash.javaMinMemory",
		"stash.javaMaxMemory",           "stash.javaMaxPermSize",
		"stash.processSearchParameter1", "stash.processSearchParameter2"
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

	#Edit Stash config file to reference homedir
	$log->info( "$subname: Applying homedir in " . $initPropertiesFile );
	print "Applying home directory to config...\n\n";
	updateLineInFile(
		$initPropertiesFile,
		"STASH_HOME=",
		"STASH_HOME=\""
		  . escapeFilePath( $globalConfig->param("$lcApplication.dataDir") )
		  . "\"",
		"#STASH_HOME="
	);
	
@parameterNull = $globalConfig->param("$lcApplication.javaParams");
if ( ( $#parameterNull == -1 )
	|| $globalConfig->param("$lcApplication.javaParams") eq "" || $globalConfig->param("$lcApplication.javaParams") eq "default" )
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
		$globalConfig->param( $lcApplication . ".javaParams" )
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
		escapeFilePath( $globalConfig->param("$lcApplication.installDir") ),
		"/bin/start-stash.sh", "/bin/stop-stash.sh" );

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
	my $subname = ( caller(0) )[3];

	$log->info("BEGIN: $subname");

	#Set up list of config items that are requred for this install to run
	$lcApplication       = lc($application);
	@requiredConfigItems = (
		"stash.appContext",              "stash.enable",
		"stash.dataDir",                 "stash.installDir",
		"stash.runAsService",            "stash.serverPort",
		"stash.connectorPort",           "stash.osUser",
		"stash.webappDir",               "stash.javaMinMemory",
		"stash.javaMaxMemory",           "stash.javaMaxPermSize",
		"stash.processSearchParameter1", "stash.processSearchParameter2"
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

	#Edit Stash config file to reference homedir
	$log->info( "$subname: Applying homedir in " . $initPropertiesFile );
	print "Applying home directory to config...\n\n";
	updateLineInFile(
		$initPropertiesFile,
		"STASH_HOME=",
		"STASH_HOME=\""
		  . escapeFilePath( $globalConfig->param("$lcApplication.dataDir") )
		  . "\"",
		"#STASH_HOME="
	);

@parameterNull = $globalConfig->param("$lcApplication.javaParams");
if ( ( $#parameterNull == -1 )
	|| $globalConfig->param("$lcApplication.javaParams") eq "" || $globalConfig->param("$lcApplication.javaParams") eq "default" )
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
		$globalConfig->param( $lcApplication . ".javaParams" )
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
		escapeFilePath( $globalConfig->param("$lcApplication.installDir") ),
		"/bin/start-stash.sh", "/bin/stop-stash.sh" );

	#Finally run generic post install tasks
	postUpgradeGeneric($application);
}

#######################################################################
#END STASH MANAGER FUNCTIONS                                          #
#######################################################################

bootStrapper();
