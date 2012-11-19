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
use strict;                    # Good practice
use warnings;                  # Good practice

########################################
#Set Up Variables                      #
########################################
my $globalConfig;
my $configFile = "settings.cfg";
my $distro;

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
#getUserUidGid                         #
########################################
sub getUserUidGid {
	my $osUser;
	my $login;
	my $pass;
	my $uid;
	my $gid;
	my @return;

	$osUser = $_[0];

	( $login, $pass, $uid, $gid ) = getpwnam($osUser)
	  or die "$osUser not in passwd file";

	@return = ( $uid, $gid );
	return @return;
}

########################################
#ChownRecursive                        #
########################################
sub chownRecursive {
	my $uid;
	my $gid;
	my $directory;

	$uid       = $_[0];
	$gid       = $_[1];
	$directory = $_[2];

	print "Chowning files to correct user. Please wait.\n\n";

	find(
		sub {
			chown $uid, $gid, $_
			  or die "could not chown '$_': $!";
		},
		$directory
	);

	print "Files chowned successfully.\n\n";
}

########################################
#ChownFile                             #
########################################
sub chownFile {
	my $uid;
	my $gid;
	my $file;

	$uid  = $_[0];
	$gid  = $_[1];
	$file = $_[2];

	print "Chowning file to correct user. Please wait.\n\n";

	chown $uid, $gid, $file
	  or die "could not chown '$_': $!";

	print "File chowned successfully.\n\n";
}

########################################
#CreateOSUser                           #
########################################
sub createOSUser {
	my $osUser;

	$osUser = $_[0];

	if ( !getpwnam($osUser) ) {
		system("useradd $osUser");
		if ( $? == -1 ) {
			die "could not create system user $osUser";
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

	$dbType = $_[0];
	$cfg    = $_[1];

	print
"Not all the Atlassian products come with the $dbType connector so we need to download it.\n\n";
	if ( $dbType eq "MySQL" ) {
		print
"In a web browser please visit http://dev.mysql.com/downloads/connector/j/ and note down the version number (such as 5.2.22).\n";
		print "Enter the version number displayed on the page above: ";
		while ( $LOOP == 1 ) {
			$input = getGenericInput();
			if ( $input eq "default" ) {
				print
"You did not enter anything, please enter a valid version number: ";
			}
			else {
				$url =
"http://cdn.mysql.com/Downloads/Connector-J/mysql-connector-java-"
				  . $input
				  . ".tar.gz";
				if ( head($url) ) {
					$LOOP = 0;
				}
				else {
					print
"That is not a valid version, no such URL with that version exists. Please try again: ";
				}
			}
		}

	}
	elsif ( $dbType eq "PostgreSQL" ) {
		print
"In a web browser please visit http://jdbc.postgresql.org/download.html and note down the version number of the JDBC4 driver (such as 9.2-1002).\n";
		print "Enter the version number displayed on the page above: ";
		while ( $LOOP == 1 ) {
			$input = getGenericInput();
			if ( $input eq "default" ) {
				print
"You did not enter anything, please enter a valid version number: ";
			}
			else {
				$url =
				    "http://jdbc.postgresql.org/download/postgresql-" 
				  . $input
				  . ".jdbc4.jar";
				if ( head($url) ) {
					$LOOP = 0;
				}
				else {
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
	print "Downloading JDBC connector for $dbType...\n\n";
	$downloadResponseCode = getstore( $url, $archiveFile );

#Test if the download was a success, if not die and return HTTP response code otherwise return the absolute path to file
	if ( is_success($downloadResponseCode) ) {
		print "\n\n";
		print "Download completed successfully.\n\n";
	}
	else {
		die
"Could not download $input. HTTP Response received was: '$downloadResponseCode'";
	}

	if ( $dbType eq "MySQL" ) {

		#Make sure file exists
		if ( !-e $archiveFile ) {
			die
"File $archiveFile could not be extracted. File does not exist.\n\n";
		}

		#Set up extract object
		$ae = Archive::Extract->new( archive => $archiveFile );
		print "Extracting $archiveFile. Please wait...\n\n";

		#Extract
		$ae->extract( to => $Bin );
		if ( $ae->error ) {
			die
"Unable to extract $archiveFile. The following error was encountered: $ae->error\n\n";
		}

		print "Extracting $archiveFile has been completed.\n\n";

		$jarFile = $ae->extract_path() . "/mysql-connector-java-$input-bin.jar";
		if ( -e $jarFile ) {
			$cfg->param( "general.dbJDBCJar", $jarFile );
		}
		else {
			die
"Unable to locate the $dbType Jar file automagically ($jarFile does not exist)\nPlease locate the file and update '$configFile' and set general->dbJDBCJar to the absolute path manually.";
		}

	}
	elsif ( $dbType eq "PostgreSQL" ) {
		$jarFile = $archiveFile;
		if ( -e $jarFile ) {
			$cfg->param( "general.dbJDBCJar", $jarFile );
		}
		else {
			die
"Unable to locate the $dbType Jar file automagically ($jarFile does not exist)\nPlease locate the file and update '$configFile' and set general->dbJDBCJar to the absolute path manually.";
		}
	}
}

########################################
#findDistro                            #
########################################
sub findDistro {
	my $distribution;

	#Test for debian
	if ( -e "/etc/debian_version" ) {
		$distribution = "debian";
	}

	#Test for redhat
	elsif ( -f "/etc/redhat-release" ) {
		$distribution = "redhat";
	}

	#Otherwise distro not supported
	else {
		$distribution = "unknown";
	}

	return $distribution;
}

########################################
#CreateDirectory                       #
########################################
sub createDirectory {
	my $directory;
	my $osUser;
	my @uidGid;

	$directory = $_[0];
	$osUser    = $_[1];

	#Get UID and GID for the user
	@uidGid = getUserUidGid($osUser);

	#Check if the directory exists if so just chown it
	if ( -d $directory ) {
		print "Directory exists...\n\n";
		chownRecursive( $uidGid[0], $uidGid[1], $directory );
	}

#If the directory doesn't exist make the path to the directory (including any missing folders)
	else {
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
		chownRecursive( $uidGid[0], $uidGid[1], $directory );
	}
}

########################################
#MoveDirectory                         #
########################################
sub moveDirectory {
	my $origDirectory;
	my $newDirectory;

	$origDirectory = $_[0];
	$newDirectory  = $_[1];

	if ( move( $origDirectory, $newDirectory ) == 0 ) {
		die
"Unable to move folder $origDirectory to $newDirectory. Unknown error occured.\n\n";
	}

}

########################################
#CheckRequiredConfigItems              #
########################################
sub checkRequiredConfigItems {
	my @requiredConfigItems;
	my @parameterNull;
	my $failureCount = 0;

	@requiredConfigItems = @_;

	foreach (@requiredConfigItems) {

		#$_;
		@parameterNull = $globalConfig->param($_);
		if ( ( $#parameterNull == -1 ) || $globalConfig->param($_) eq "" ) {
			$failureCount++;
		}
	}
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

	$application = $_[0];
	$mode        = $_[1];

	#Install the service
	if ( $mode eq "INSTALL" ) {
		print "Installing Service for $application...\n\n";
		if ( $distro eq "redhat" ) {
			system("chkconfig --add $application") == 0
			  or die "Adding $application as a service failed: $?";
		}
		elsif ( $distro eq "debian" ) {
			system("update-rc.d $application defaults") == 0
			  or die "Adding $application as a service failed: $?";
		}
		print "Service installed successfully...\n\n";
	}

	#Remove the service
	elsif ( $mode eq "UNINSTALL" ) {
		print "Removing Service for $application...\n\n";
		if ( $distro eq "redhat" ) {
			system("chkconfig --del $application") == 0
			  or die "Removing $application as a service failed: $?";
		}
		elsif ( $distro eq "debian" ) {
			system("update-rc.d -f $application remove") == 0
			  or die "Removing $application as a service failed: $?";

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

	#Check for supported distribution of *nix
	$distro = findDistro();

#If distro unknown die as not supported (if you receive this in error please log a bug to me)
	if ( $distro eq "unknown" ) {
		die
"This operating system is currently unsupported. Only Redhat (and derivatives) and Debian (and derivatives) currently supported.\n\n";
	}

	#Try to load configuration file
	loadSuiteConfig();

	#If no config found, force generation
	if ( !$globalConfig ) {
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
				die "This script will now exit.\n\n";
			}
		}
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

	$product      = $_[0];
	$architecture = $_[1];

	#Build URL to check latest version for a particular product
	my $versionurl =
	  "https://my.atlassian.com/download/feeds/current/" . $product . ".json";
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

	#Try and download the feed
	my $json = get($versionurl);
	die "Could not get $versionurl!" unless defined $json;

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

	$product      = $_[0];
	$architecture = $_[1];
	$version      = $_[2];

	#Generate product specific URL
	$versionurl =
	  "http://www.atlassian.com/software/" . $product . "/downloads/binary";

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

	#Return the absolute URL to the version specific download
	@returnArray = ( $versionurl . "/" . $filename, $version );
}

########################################
#GetBooleanInput                       #
########################################
sub getBooleanInput {
	my $LOOP = 1;
	my $input;

	while ( $LOOP == 1 ) {

		$input = <STDIN>;
		print "\n\n";
		chomp $input;

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

	$input = <STDIN>;
	print "\n\n";
	chomp $input;

	if ( $input eq "" ) {
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

	$inputFile          = $_[0];
	$expectedFolderName = $_[1];
	$osUser             = $_[2];
	$mode               = $_[3];

	#Get the UID and GID for the user so that we can chown files
	@uidGid = getUserUidGid($osUser);

	print "Preparing to extract $inputFile...\n\n";

	#Make sure directory exists
	createDirectory( $globalConfig->param("general.rootInstallDir"), "root" );

	#Make sure file exists
	if ( !-e $inputFile ) {
		die "File $inputFile could not be extracted. File does not exist.\n\n";
	}

	#Set up extract object
	my $ae = Archive::Extract->new( archive => $inputFile );
	print "Extracting $inputFile. Please wait...\n\n";

	#Extract
	$ae->extract( to => $globalConfig->param("general.rootInstallDir") );
	if ( $ae->error ) {
		die
"Unable to extract $inputFile. The following error was encountered: $ae->error\n\n";
	}

	print "Extracting $inputFile has been completed.\n\n";

	#Check for existing folder and provide option to backup
	if ( -d $expectedFolderName ) {
		if ( $mode eq "UPGRADE" ) {
			print "Backing up old installation folder to $expectedFolderName"
			  . "_upgrade_"
			  . $date
			  . ", please wait...\n\n";
			moveDirectory( $expectedFolderName,
				$expectedFolderName . "_upgrade_" . $date );
			print "Old installation successfully backed up.\n\n";
			print "Moving new installation into place...\n\n";
			moveDirectory( $ae->extract_path(), $expectedFolderName );
			chownRecursive( $uidGid[0], $uidGid[1], $expectedFolderName );

		}
		else {
			my $LOOP = 1;
			my $input;

			print "The destination directory '"
			  . $expectedFolderName
			  . " already exists. Would you like to overwrite or create a backup? o=overwrite\\b=backup [b]\n";
			while ( $LOOP == 1 ) {

				$input = <STDIN>;
				chomp $input;
				print "\n\n";

				#If user selects, backup existing folder
				if (   ( lc $input ) eq "backup"
					|| ( lc $input ) eq "b"
					|| $input eq "" )
				{
					$LOOP = 0;
					moveDirectory( $expectedFolderName,
						$expectedFolderName . $date );
					print "Folder backed up to "
					  . $expectedFolderName
					  . $date . "\n\n";
					moveDirectory( $ae->extract_path(), $expectedFolderName );
					chownRecursive( $uidGid[0], $uidGid[1],
						$expectedFolderName );

				}

#If user selects, overwrite existing folder by deleting and then moving new directory in place
				elsif ( ( lc $input ) eq "overwrite" || ( lc $input ) eq "o" ) {
					$LOOP = 0;

#Considered failure handling for rmtree however based on http://perldoc.perl.org/File/Path.html used
#recommended in built error handling.
					rmtree( ["$expectedFolderName"] );

					moveDirectory( $ae->extract_path(), $expectedFolderName );
					chownRecursive( $uidGid[0], $uidGid[1],
						$expectedFolderName );
				}

				#Input was not recognised, ask user for input again
				else {
					print "Your input '" . $input
					  . "'was not recognised. Please try again and write either 'B' for backup or 'O' to overwrite [B].\n";
				}
			}
		}
	}

	#Directory does not exist, move new directory in place.
	else {
		moveDirectory( $ae->extract_path(), $expectedFolderName );
		chownRecursive( $uidGid[0], $uidGid[1], $expectedFolderName );
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

	$mode              = $_[0];
	$cfg               = $_[1];
	$configParam       = $_[2];
	$messageText       = $_[3];
	$defaultInputValue = $_[4];

	#Check if the paramater is null (undefined)
	@parameterNull = $cfg->param($configParam);

#Check if we are updating (get current value), or doing a fresh run (use default passed to this function)
	if ( $mode eq "UPDATE" ) {

		#Check if the current value is defined
		if ( defined( $cfg->param($configParam) ) & !( $#parameterNull == -1 ) )
		{
			$defaultValue = $cfg->param($configParam);
		}
		else {
			$defaultValue = $defaultInputValue;
		}
	}
	else {
		$defaultValue = $defaultInputValue;
	}
	print $messageText . " [" . $defaultValue . "]: ";

	$input = getGenericInput();
	print "\n\n";

#If default option is selected (i.e. just a return), use default value, otherwise use input
	if ( $input eq "default" ) {
		$cfg->param( $configParam, $defaultValue );
	}
	else {
		$cfg->param( $configParam, $input );
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

	$mode              = $_[0];
	$cfg               = $_[1];
	$configParam       = $_[2];
	$messageText       = $_[3];
	$defaultInputValue = $_[4];

	#Check if parameter is null (undefined)
	@parameterNull = $cfg->param($configParam);

#Check if we are updating (get current value), or doing a fresh run (use default passed to this function)
	if ( $mode eq "UPDATE" ) {

		#Check if the current value is defined
		if ( defined( $cfg->param($configParam) ) & !( $#parameterNull == -1 ) )
		{
			if ( $cfg->param($configParam) eq "TRUE" ) {
				$defaultValue = "yes";
			}
			elsif ( $cfg->param($configParam) eq "FALSE" ) {
				$defaultValue = "no";
			}
		}
		else {
			$defaultValue = $defaultInputValue;
		}
	}
	else {
		$defaultValue = $defaultInputValue;
	}
	print $messageText . " [" . $defaultValue . "]: ";

	$input = getBooleanInput();
	print "\n\n";

#If default option is selected (i.e. just a return), use default value, set to boolean value based on return
	if ( $input eq "yes"
		|| ( $input eq "default" && $defaultValue eq "yes" ) )
	{
		$cfg->param( $configParam, "TRUE" );
	}
	elsif ( $input eq "no"
		|| ( $input eq "default" && $defaultValue eq "no" ) )
	{
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

	$xmlFile            = $_[0];
	$searchString       = $_[1];
	$referenceAttribute = $_[2];
	$attributeValue     = $_[3];

	#Set up new XML object, with "pretty" spacing (i.e. standard spacing)
	my $twig = new XML::Twig( pretty_print => 'indented', );

	#Parse the XML file
	$twig->parsefile($xmlFile);

	#Find the node we are looking for based on the provided search string
	for my $node ( $twig->findnodes($searchString) ) {

		#Set the node to the new attribute value
		$node->set_att( $referenceAttribute => $attributeValue );
	}

	#Print the new XML tree back to the original file
	$twig->print_to_file($xmlFile);
}

########################################
#updateJAVAOPTS                        #
########################################
sub updateJavaOpts {
	my $inputFile;    #Must Be Absolute Path
	my $javaOpts;
	my $searchFor;
	my @data;

	$inputFile = $_[0];
	$javaOpts  = $_[1];

	#Try to open the provided file
	open( FILE, $inputFile ) or die("Unable to open file: $inputFile");

	# read file into an array
	@data = <FILE>;

	close(FILE);

	$searchFor = "JAVA_OPTS";

	#Search for the provided string in the file array
	my ($index1) = grep { $data[$_] =~ /^$searchFor.*/ } 0 .. $#data;

#See how many times ATLASMGR_JAVA_OPTS occurs in file, this will be in the existing
#JAVA_OPTS parameter as a variable.
#If it doesn't exist this splits up the string so that we can insert it as a new variable
	my $count = grep( /.*ATLASMGR_JAVA_OPTS.*/, $data[$index1] );
	if ( $count == 0 ) {
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
		splice( @data, $index1, 0,
			"ATLASMGR_JAVA_OPTS=\"" . $javaOpts . "\"\n" );
	}

	#Else update the line to have the new parameters that have been specified
	else {
		$data[$index2] = "ATLASMGR_JAVA_OPTS=\"" . $javaOpts . "\"\n";
	}

	#Try to open file, output the lines that are in memory and close
	open FILE, ">$inputFile" or die $!;
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

	$inputFile      = $_[0];
	$lineReference  = $_[1];
	$newLine        = $_[2];
	$lineReference2 = $_[3];

	open( FILE, $inputFile ) or die("Unable to open file: $inputFile.");

	# read file into an array
	@data = <FILE>;

	close(FILE);

	#Search for reference line
	my ($index1) = grep { $data[$_] =~ /^$lineReference.*/ } 0 .. $#data;

	#If you cant find the first reference try for the second reference
	if ( !defined($index1) ) {
		if ( defined($lineReference2) ) {
			my ($index1) =
			  grep { $data[$_] =~ /^$lineReference2.*/ } 0 .. $#data;
			if ( !defined($index1) ) {
				die(
"No line containing \"$lineReference\" found in file $inputFile\n\n"
				);
			}

			#Otherwise replace the line with the new provided line
			else {
				$data[$index1] = $newLine . "\n";
			}
		}
		else {
			die(
"No line containing \"$lineReference\" found in file $inputFile\n\n"
			);
		}
	}
	else {
		$data[$index1] = $newLine . "\n";
	}

	#Write out the updated file
	open FILE, ">$inputFile" or die $!;
	print FILE @data;
	close FILE;

}

########################################
#isSupportedVersion                   #
########################################
sub isSupportedVersion {
	my $product;    #Must Be Absolute Path
	my $version;
	my @splitVersion;
	my @productArray;
	my $count;
	my $majorVersionStatus;
	my $midVersionStatus;

	$product = $_[0];
	$version = $_[1];

	#Set up maximum supported versions
	my @jiraSupportedVerHigh       = ( 5, 2 );
	my @confluenceSupportedVerHigh = ( 4, 3, 2 );
	my @crowdSupportedVerHigh      = ( 2, 5, 2 );
	my @fisheyeSupportedVerHigh    = ( 2, 9, 0 );
	my @bambooSupportedVerHigh     = ( 4, 3, 1 );
	my @stashSupportedVerHigh      = ( 1, 3, 1 );

	@splitVersion = split( /\./, $version );

	#Set up supported version for each product
	if ( $product eq "confluence" ) {
		@productArray = @confluenceSupportedVerHigh;
	}
	elsif ( $product eq "jira" ) {
		@productArray = @jiraSupportedVerHigh;
	}
	elsif ( $product eq "stash" ) {
		@productArray = @stashSupportedVerHigh;
	}
	elsif ( $product eq "fisheye" ) {
		@productArray = @fisheyeSupportedVerHigh;
	}
	elsif ( $product eq "crowd" ) {
		@productArray = @crowdSupportedVerHigh;
	}
	elsif ( $product eq "bamboo" ) {
		@productArray = @bambooSupportedVerHigh;
	}
	else {
		print
"That package is not recognised - Really you should never get here so if you managed to *wavesHi*";
		exit 2;
	}

#Iterate through supported version array and test if the version provided is less than or equal to the supported version
	my $supported;
	for ( $count = 0 ; $count <= $#productArray ; $count++ ) {
		if ( $splitVersion[$count] <= $productArray[$count] ) {
			$supported = 1;
			if ( $count == 0 ) {
				if ( $splitVersion[$count] < $productArray[$count] ) {
					$majorVersionStatus = "LESS";
				}
				else {
					$majorVersionStatus = "EQUAL";
				}

			}
			elsif ( $count == 1 ) {
				if ( $splitVersion[$count] < $productArray[$count] ) {
					$midVersionStatus = "LESS";
				}
				else {
					$midVersionStatus = "EQUAL";
				}
			}
		}
		else {
			if ( $count == 0 ) {
				$supported = 0;
				last;
			}
			elsif ( ( $count == 1 ) & ( $majorVersionStatus eq "LESS" ) ) {
				$supported = 1;
				last;
			}
			elsif ( ( $count == 2 ) & ( $majorVersionStatus eq "LESS" ) &
				( $midVersionStatus eq "LESS" ) )
			{
				$supported = 1;
				last;
			}
			elsif ( ( $count == 2 ) & ( $majorVersionStatus eq "EQ" ) &
				( $midVersionStatus eq "LESS" ) )
			{
				$supported = 1;
				last;
			}
			else {
				$supported = 0;
				last;
			}

		}
	}

	#If the version is supported return true
	if ( $supported == 1 ) {
		return "yes";
	}
	else {
		return "no";
	}

}

########################################
#backupFile                            #
########################################
sub backupFile {
	my $inputDir;
	my $outputDir;
	my $inputFile;
	my $date = strftime "%Y%m%d_%H%M%S", localtime;

	$inputDir  = $_[0];
	$outputDir = $_[1];
	$inputFile = $_[2];

	#Create copy of input file with date_time appended to the end of filename
	copy( $inputDir . "/" . $inputFile,
		$outputDir . "/" . $inputFile . "_" . $date )
	  or die "Copy failed: $!";
}

########################################
#GenerateInitD                         #
########################################
sub generateInitD {
	my $product;
	my $runUser;
	my $baseDir;
	my $startCmd;
	my $stopCmd;
	my @initFile;

	$product  = $_[0];
	$runUser  = $_[1];
	$baseDir  = $_[2];
	$startCmd = $_[3];
	$stopCmd  = $_[4];

	#generate INITD file
	@initFile = (
		"#!/bin/sh -e\n",
		"#" . $product . " startup script\n",
		"#chkconfig: 2345 80 05\n",
		"#description: " . $product . "\n",
		"\n",
		"APP=" . $product . "\n",
		"USER=" . $runUser . "\n",
		"BASE=" . $baseDir . "\n",
		"STARTCOMMAND=" . $startCmd . "\n",
		"STOPCOMMAND=" . $stopCmd . "\n",
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
	open FILE, ">/etc/init.d/$product" or die $!;
	print FILE @initFile;
	close FILE;

	#Make the new init.d file executable
	chmod 0755, "/etc/init.d/$product"
	  or die "Couldn't chmod /etc/init.d/$product: $!";

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
#InstallCrowd                          #
########################################
sub installCrowd {
	my $input;
	my $mode;
	my $version;
	my $application = "crowd";
	my @downloadDetails;
	my $archiveLocation;
	my $osUser;
	my $VERSIONLOOP = 1;
	my @uidGid;

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
		print
"Some of the Crowd config parameters are incomplete. You must review the Crowd configuration before continuing: \n\n";
		generateCrowdConfig( "UPDATE", $globalConfig );
		$globalConfig->write($configFile);
		loadSuiteConfig();
	}

	#Otherwise provide the option to update the configuration before proceeding
	else {
		print
"Would you like to review the Crowd config before installing? Yes/No [yes]: ";

		$input = getBooleanInput();
		print "\n\n";
		if ( $input eq "default" || $input eq "yes" ) {
			generateCrowdConfig( "UPDATE", $globalConfig );
			$globalConfig->write($configFile);
			loadSuiteConfig();
		}
	}

	#Get the user Crowd will run as
	$osUser = $globalConfig->param("crowd.osUser");

	#Check the user exists or create if not
	createOSUser($osUser);

	print "Would you like to install the latest version? yes/no [yes]: ";

	$input = getBooleanInput();
	print "\n\n";
	if ( $input eq "default" || $input eq "yes" ) {
		$mode = "LATEST";
	}
	else {
		$mode = "SPECIFIC";
	}

	#If a specific version is selected, ask for the version number
	if ( $mode eq "SPECIFIC" ) {
		while ( $VERSIONLOOP == 1 ) {
			print
			  "Please enter the version number you would like. i.e. 4.2.2 []: ";

			$version = <STDIN>;
			print "\n\n";
			chomp $version;

			#Check that the input version actually exists
			print
"Please wait, checking that version $version of Crowd exists (may take a few moments)... \n\n";

			#get the version specific URL to test
			@downloadDetails =
			  getVersionDownloadURL( $application,
				whichApplicationArchitecture(), $version );

			#Try to get the header of the version URL to ensure it exists
			if ( head( $downloadDetails[0] ) ) {
				$VERSIONLOOP = 0;
				print "Crowd version $version found. Continuing...\n\n";
			}
			else {
				print
"No such version of Crowd exists. Please visit http://www.atlassian.com/software/crowd/download-archive and pick a valid version number and try again.\n\n";
			}
		}

	}

	#Download the latest version
	if ( $mode eq "LATEST" ) {
		@downloadDetails =
		  downloadAtlassianInstaller( $mode, $application, "",
			whichApplicationArchitecture() );

	}

	#Download a specific version
	else {
		@downloadDetails =
		  downloadAtlassianInstaller( $mode, $application, $version,
			whichApplicationArchitecture() );
	}

	#Extract the download and move into place
	extractAndMoveDownload( $downloadDetails[2],
		$globalConfig->param("crowd.installDir"),
		$osUser, "" );

	print "Applying configuration settings to the install, please wait...\n\n";

	#Update the server config with the configured connector port
	updateXMLAttribute(
		$globalConfig->param("crowd.installDir")
		  . "/apache-tomcat/conf/server.xml",
		"///Connector", "port", $globalConfig->param("crowd.connectorPort")
	);

	#Update the server config with the configured server port
	updateXMLAttribute(
		$globalConfig->param("crowd.installDir")
		  . "/apache-tomcat/conf/server.xml",
		"/Server", "port", $globalConfig->param("crowd.serverPort")
	);

	#EditFileToReferenceHomedir
	updateLineInFile(
		$globalConfig->param("crowd.installDir")
		  . "/crowd-webapp/WEB-INF/classes/crowd-init.properties",
		"crowd.home",
		"crowd.home=" . $globalConfig->param("crowd.dataDir"),
		"#crowd.home=/var/crowd-home"
	);

	print "Configuration settings have been applied successfully.\n\n";

	if ( $globalConfig->param("general.targetDBType") eq "MySQL" ) {
		print
"Database is configured as MySQL, copying the JDBC connector to Crowd install.\n\n";
		copy( $globalConfig->param("general.dbJDBCJar"),
			$globalConfig->param("crowd.installDir") . "/apache-tomcat/lib/" )
		  or die
		  "Unable to copy MySQL JDBC connector to Crowd lib directory: $!";

		#Get UID and GID for the user
		@uidGid = getUserUidGid($osUser);

		#Chown the files again
		chownRecursive( $uidGid[0], $uidGid[1],
			$globalConfig->param("crowd.installDir") . "/apache-tomcat/lib/" );
	}

	#Create home/data directory if it does not exist
	print
"Checking if data directory exists and creating if not, please wait...\n\n";
	createDirectory( $globalConfig->param("crowd.dataDir"), $osUser );

	print
"Setting up initd files and run as a service (if configured) please wait...\n\n";

	#Generate the init.d file
	generateInitD( $application, $osUser,
		$globalConfig->param("crowd.installDir"),
		"start_crowd.sh", "stop_crowd.sh" );

	#If set to run as a service, set to run on startup
	if ( $globalConfig->param("crowd.runAsService") eq "TRUE" ) {
		manageService( "INSTALL", $application );
	}
	print "Services configured successfully.\n\n";

	#Check if we should start the service
	print
"Installation has completed successfully. Would you like to Start the Crowd service now? Yes/No [yes]: ";
	$input = getBooleanInput();
	print "\n\n";
	if ( $input eq "default" || $input eq "yes" ) {
		system("service $application start");
	}
}

########################################
#UpgradeCrowd                        #
########################################
sub upgradeCrowd {
	my $input;
	my $mode;
	my $version;
	my $application = "crowd";
	my @downloadDetails;
	my $archiveLocation;
	my $osUser;
	my $VERSIONLOOP = 1;
	my @uidGid;

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
		print
"Some of the Crowd config parameters are incomplete. You must review the Crowd configuration before continuing: \n\n";
		generateCrowdConfig( "UPDATE", $globalConfig );
		$globalConfig->write($configFile);
		loadSuiteConfig();
	}

	#Otherwise provide the option to update the configuration before proceeding
	else {
		print
"Would you like to review the Crowd config before upgrading? Yes/No [yes]: ";

		$input = getBooleanInput();
		print "\n\n";
		if ( $input eq "default" || $input eq "yes" ) {
			generateCrowdConfig( "UPDATE", $globalConfig );
			$globalConfig->write($configFile);
			loadSuiteConfig();
		}
	}

	#Get the user Crowd will run as
	$osUser = $globalConfig->param("crowd.osUser");

	#Check the user exists or create if not
	createOSUser($osUser);

	#We are upgrading, get the latest version
	$mode = "LATEST";

	#Download the latest version
	if ( $mode eq "LATEST" ) {
		@downloadDetails =
		  downloadAtlassianInstaller( $mode, $application, "",
			whichApplicationArchitecture() );

	}

	#Download a specific version
	else {
		@downloadDetails =
		  downloadAtlassianInstaller( $mode, $application, $version,
			whichApplicationArchitecture() );
	}

	#Extract the download and move into place
	extractAndMoveDownload( $downloadDetails[2],
		$globalConfig->param("crowd.installDir"),
		$osUser, "UPGRADE" );

	print "Applying configuration settings to the install, please wait...\n\n";

	#Update the server config with the configured connector port
	updateXMLAttribute(
		$globalConfig->param("crowd.installDir")
		  . "/apache-tomcat/conf/server.xml",
		"///Connector", "port", $globalConfig->param("crowd.connectorPort")
	);

	#Update the server config with the configured server port
	updateXMLAttribute(
		$globalConfig->param("crowd.installDir")
		  . "/apache-tomcat/conf/server.xml",
		"/Server", "port", $globalConfig->param("crowd.serverPort")
	);

	#EditFileToReferenceHomedir
	updateLineInFile(
		$globalConfig->param("crowd.installDir")
		  . "/crowd-webapp/WEB-INF/classes/crowd-init.properties",
		"crowd.home",
		"crowd.home=" . $globalConfig->param("crowd.dataDir"),
		"#crowd.home=/var/crowd-home"
	);

	print "Configuration settings have been applied successfully.\n\n";

	if ( $globalConfig->param("general.targetDBType") eq "MySQL" ) {
		print
"Database is configured as MySQL, copying the JDBC connector to Crowd install.\n\n";
		copy( $globalConfig->param("general.dbJDBCJar"),
			$globalConfig->param("crowd.installDir") . "/apache-tomcat/lib/" )
		  or die
		  "Unable to copy MySQL JDBC connector to Crowd lib directory: $!";

		#Get UID and GID for the user
		@uidGid = getUserUidGid($osUser);

		#Chown the files again
		chownRecursive( $uidGid[0], $uidGid[1],
			$globalConfig->param("crowd.installDir") . "/apache-tomcat/lib/" );
	}

	#Set up init.d again just incase any params have changed.
	print
"Setting up initd files and run as a service (if configured) please wait...\n\n";

	#Generate the init.d file
	generateInitD( $application, $osUser,
		$globalConfig->param("crowd.installDir"),
		"start_crowd.sh", "stop_crowd.sh" );

	#If set to run as a service, set to run on startup
	if ( $globalConfig->param("crowd.runAsService") eq "TRUE" ) {
		manageService( "INSTALL", $application );
	}
	print "Services configured successfully.\n\n";

	#Check if we should start the service
	print
"Upgrade has completed successfully. Would you like to Start the Crowd service now? Yes/No [yes]: ";
	$input = getBooleanInput();
	print "\n\n";
	if ( $input eq "default" || $input eq "yes" ) {
		system("service $application start");
	}
}

########################################
#GenerateJiraConfig                    #
########################################
sub generateJiraConfig {
	my $cfg;
	my $mode;
	my $input;
	my $defaultValue;

	$mode = $_[0];
	$cfg  = $_[1];

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
"Enter the context that Jira should run under (i.e. /jira or /bugtraq). Leave blank to keep default context.",
		""
	);
	genConfigItem(
		$mode,
		$cfg,
		"jira.connectorPort",
"Please enter the Connector port Jira will run on (note this is the port you will access in the browser).",
		"8080"
	);
	genConfigItem(
		$mode,
		$cfg,
		"jira.serverPort",
"Please enter the SERVER port Jira will run on (note this is the control port not the port you access in a browser).",
		"8000"
	);
	genConfigItem(
		$mode,
		$cfg,
		"jira.javaParams",
"Enter any additional paramaters you would like to add to the Java RUN_OPTS.",
		""
	);

}

########################################
#GenerateCrowdConfig                   #
########################################
sub generateCrowdConfig {
	my $cfg;
	my $mode;
	my $input;
	my $defaultValue;

	$mode = $_[0];
	$cfg  = $_[1];

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
"Enter the context that Crowd should run under (i.e. /crowd or /login). Leave blank to keep default context.",
		"/crowd"
	);
	genConfigItem(
		$mode,
		$cfg,
		"crowd.connectorPort",
"Please enter the Connector port Crowd will run on (note this is the port you will access in the browser).",
		"8095"
	);
	genConfigItem(
		$mode,
		$cfg,
		"crowd.serverPort",
"Please enter the SERVER port Crowd will run on (note this is the control port not the port you access in a browser).",
		"8000"
	);

	genBooleanConfigItem( $mode, $cfg, "crowd.runAsService",
		"Would you like to run Crowd as a service? yes/no.", "yes" );

	genConfigItem(
		$mode,
		$cfg,
		"crowd.javaParams",
"Enter any additional paramaters you would like to add to the Java RUN_OPTS.",
		""
	);

}

########################################
#GenerateFisheyeConfig                 #
########################################
sub generateFisheyeConfig {
	my $cfg;
	my $mode;
	my $input;
	my $defaultValue;

	$mode = $_[0];
	$cfg  = $_[1];

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
	genConfigItem( $mode, $cfg, "fisheye.serverPort",
		"Please enter the SERVER port Fisheye will run on.", "8060" );
	genConfigItem(
		$mode,
		$cfg,
		"fisheye.javaParams",
"Enter any additional paramaters you would like to add to the Java RUN_OPTS.",
		""
	);

}

########################################
#GenerateConfluenceConfig              #
########################################
sub generateConfluenceConfig {
	my $cfg;
	my $mode;
	my $input;
	my $defaultValue;

	$mode = $_[0];
	$cfg  = $_[1];

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
"Enter the context that Confluence should run under (i.e. /wiki or /confluence). Leave blank to keep default context.",
		""
	);
	genConfigItem(
		$mode,
		$cfg,
		"confluence.connectorPort",
"Please enter the Connector port Confluence will run on (note this is the port you will access in the browser).",
		"8090"
	);
	genConfigItem(
		$mode,
		$cfg,
		"confluence.serverPort",
"Please enter the SERVER port Confluence will run on (note this is the control port not the port you access in a browser).",
		"8000"
	);
	genConfigItem(
		$mode,
		$cfg,
		"confluence.javaParams",
"Enter any additional paramaters you would like to add to the Java RUN_OPTS.",
		""
	);

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

	$type         = $_[0];
	$product      = $_[1];
	$version      = $_[2];
	$architecture = $_[3];

	print "Beginning download of $product, please wait...\n\n";

	#Get the URL for the version we want to download
	if ( $type eq "LATEST" ) {
		@downloadDetails = getLatestDownloadURL( $product, $architecture );
	}
	else {
		@downloadDetails =
		  getVersionDownloadURL( $product, $architecture, $version );
	}

	#Check if we are trying to download a supported version
	if ( isSupportedVersion( $product, $downloadDetails[1] ) eq "no" ) {
		print
"This version of $product ($downloadDetails[1]) has not been fully tested with this script. Do you wish to continue?: [yes]";

		$input = getBooleanInput();
		print "\n\n";
		if ( $input eq "no" ) {
			return;
		}
	}

	#Parse the URL so that we can get specific sections of it
	$parsedURL = URI->new( $downloadDetails[0] );
	my @bits = $parsedURL->path_segments();

	#Set the download to show progress as we download
	$ua->show_progress(1);

	#Check that the install/download directory exists, if not create it
	print "Checking that root install dir exists...\n\n";
	createDirectory( $globalConfig->param("general.rootInstallDir"), "root" );

	#Download the file and store the HTTP response code
	print "Downloading file from Atlassian...\n\n";
	$downloadResponseCode = getstore( $downloadDetails[0],
		    $globalConfig->param("general.rootInstallDir") . "/"
		  . $bits[ @bits - 1 ] );

#Test if the download was a success, if not die and return HTTP response code otherwise return the absolute path to file
	if ( is_success($downloadResponseCode) ) {
		print "\n\n";
		print "Download completed successfully.\n\n";
		$downloadDetails[2] =
		    $globalConfig->param("general.rootInstallDir") . "/"
		  . $bits[ @bits - 1 ];
		return @downloadDetails;
	}
	else {
		die
"Could not download $product version $version. HTTP Response received was: '$downloadResponseCode'";
	}

}

########################################
#Download Full Suite                   #
########################################
sub downloadLatestAtlassianSuite {
	my $downloadURL;
	my $architecture;
	my $parsedURL;
	my @downloadDetails;
	my @suiteProducts;

	$architecture = $_[0];

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
#GenerateSuiteConfig                   #
########################################
sub generateSuiteConfig {
	my $cfg;
	my $mode;
	my $input;
	my $defaultValue;
	my @parameterNull;
	my $oldConfig;

	#Check if we have a valid config file already, if so we are updating it
	if ($globalConfig) {
		$mode      = "UPDATE";
		$cfg       = $globalConfig;
		$oldConfig = new Config::Simple($configFile);
	}

	#Otherwise we are creating a new file
	else {
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
		  "Do you wish to set up/update the Crowd configuration now? [no] \n\n";

		$input = getBooleanInput();

		if ( $input eq "yes" ) {
			generateCrowdConfig( $mode, $cfg );
		}

	}

	#Get Jira configuration
	genBooleanConfigItem( $mode, $cfg, "jira.enable",
		"Do you wish to install/manage Jira? yes/no ", "yes" );

	if ( $cfg->param("jira.enable") eq "TRUE" ) {
		print
		  "Do you wish to set up/update the Jira configuration now? [no] \n\n";

		$input = getBooleanInput();

		if ( $input eq "yes" ) {
			generateJiraConfig( $mode, $cfg );
		}
	}

	#Get Confluence configuration
	genBooleanConfigItem( $mode, $cfg, "confluence.enable",
		"Do you wish to install/manage Confluence? yes/no ", "yes" );

	if ( $cfg->param("confluence.enable") eq "TRUE" ) {
		print
"Do you wish to set up/update the Confluence configuration now? [no] \n\n";

		$input = getBooleanInput();

		if ( $input eq "yes" ) {
			generateConfluenceConfig( $mode, $cfg );
		}
	}

	#Get Fisheye configuration
	genBooleanConfigItem( $mode, $cfg, "fisheye.enable",
		"Do you wish to install/manage Fisheye? yes/no ", "yes" );

	if ( $cfg->param("fisheye.enable") eq "TRUE" ) {
		print
"Do you wish to set up/update the Fisheye configuration now? [no] \n\n";

		$input = getBooleanInput();

		if ( $input eq "yes" ) {
			generateJiraConfig( $mode, $cfg );
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
		print "\n\n";

		if (   ( lc $input ) eq "1"
			|| ( lc $input ) eq "mysql" )
		{
			$LOOP = 0;
			$cfg->param( "general.targetDBType", "MySQL" );
		}
		elsif (( lc $input ) eq "2"
			|| ( lc $input ) eq "postgresql"
			|| ( lc $input ) eq "postgres"
			|| ( lc $input ) eq "postgre" )
		{
			$LOOP = 0;
			$cfg->param( "general.targetDBType", "PostgreSQL" );
		}
		elsif (( lc $input ) eq "3"
			|| ( lc $input ) eq "oracle" )
		{
			$LOOP = 0;
			$cfg->param( "general.targetDBType", "Oracle" );
		}
		elsif (( lc $input ) eq "4"
			|| ( lc $input ) eq "microsoft sql server"
			|| ( lc $input ) eq "mssql" )
		{
			$LOOP = 0;
			$cfg->param( "general.targetDBType", "MSSQL" );
		}
		elsif (( lc $input ) eq "5"
			|| ( lc $input ) eq "hsqldb"
			|| ( lc $input ) eq "hsql" )
		{
			$LOOP = 0;
			$cfg->param( "general.targetDBType", "HSQLDB" );
		}
		elsif ( ( lc $input ) eq "" & ( $#parameterNull == -1 ) ) {
			print
			  "You did not make a selection please enter 1, 2, 3, 4 or 5. \n\n";
		}
		elsif ( ( lc $input ) eq "" & !( $#parameterNull == -1 ) ) {

			#keepExistingValueWithNoChange
			$LOOP = 0;
		}
		else {
			print "Your input '" . $input
			  . "'was not recognised. Please try again and enter either 1, 2, 3, 4 or 5. \n\n";
		}
	}
	if ( defined($oldConfig) ) {
		if ( $cfg->param("general.targetDBType") ne
			$oldConfig->param("general.targetDBType") )
		{

#Database selection has changed therefore NULL the dbJDBCJar config option to ensure it gets a new value appropriate to the new DB
			$cfg->param( "general.dbJDBCJar", "" );
		}
	}
	@parameterNull = $cfg->param("general.dbJDBCJar");

	if ( $cfg->param("general.targetDBType") eq "MySQL" &
		( $#parameterNull == -1 ) )
	{
		downloadJDBCConnector( "MySQL", $cfg );
	}
	elsif ( $cfg->param("general.targetDBType") eq "PostgreSQL" &
		( $#parameterNull == -1 ) )
	{
		downloadJDBCConnector( "PostgreSQL", $cfg );
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
		$cfg->write($configFile);
		exit;
	}

	#Write config and reload
	$cfg->write($configFile);
	loadSuiteConfig();
}

########################################
#Display Install Menu                  #
########################################
sub displayMenu {
	my $choice;
	my $main_menu;

	my $LOOP = 1;
	while ( $LOOP == 1 ) {

		# define the main menu as a multiline string
		$main_menu = <<'END_TXT';

      Welcome to the Atlassian Suite Manager Script

      AtlassianSuiteManager Copyright (C) 2012  Stuart Ryan
      This program comes with ABSOLUTELY NO WARRANTY;
      This is free software, and you are welcome to redistribute it
      under certain conditions; read the COPYING file included for details.


      Please select from the following options:

      1) server1
      2) server5
      3) server7
      4) server8
      Q) Quit

END_TXT

		# print the main menu
		system 'clear';
		print $main_menu;

		# prompt for user's choice
		printf( "%s", "enter selection: " );

		# capture the choice
		$choice = <STDIN>;

		# and finally print it
		#print "You entered: ",$choice;
		if ( $choice eq "Q\n" || $choice eq "q\n" ) {
			$LOOP = 0;
			exit 0;
		}
	}
}
bootStrapper();

#generateSuiteConfig();
#getVersionDownloadURL( "confluence", whichApplicationArchitecture(), "4.2.7" );

#updateJavaOpts ("/opt/atlassian/confluence/bin/setenv.sh", "-Djavax.net.ssl.trustStore=/usr/java/default/jre/lib/security/cacerts");

#isSupportedVersion( "confluence", "5.1.1" );

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

#downloadAtlassianInstaller( "SPECIFIC", "crowd", "2.5.2",
#	whichApplicationArchitecture() );

#downloadJDBCConnector("PostgreSQL");

upgradeCrowd();