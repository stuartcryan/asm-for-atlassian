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

use LWP::Simple;               # From CPAN
use LWP::Simple qw($ua getstore);
use JSON qw( decode_json );    # From CPAN
use JSON qw( from_json );      # From CPAN
use URI;                       # From CPAN
use Data::Dumper;              # Perl core module
use Config::Simple;            # From CPAN
use strict;                    # Good practice
use warnings;                  # Good practice

########################################
#Set Up Variables                      #
########################################
my $globalConfig;

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
#WhichApplicationArchitecture          #
########################################
sub whichApplicationArchitecture {
	if (testOSArchitecture() eq "64") {
		if ( $globalConfig->param("general.force32Bit") eq "TRUE" ) {
			return "32";
		} else {
			return "64";
		}
	}
	else {
		return "64";
	}
}

########################################
#Get the latest URL to download XXX    #
########################################
sub getLatestDownloadURL {
	my $product;
	my $architecture;
	
	$product = $_[0];
	$architecture = $_[1];
	
	my $versionurl =
	  "https://my.atlassian.com/download/feeds/current/" . $product . ".json";
	my $searchString;

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

	my $json = get($versionurl);

	die "Could not get $versionurl!" unless defined $json;

 #We have to rework the string slightly as Atlassian is not returning valid JSON
	$json = substr( $json, 10, -1 );
	$json = '{ "downloads": ' . $json . '}';

	# Decode the entire JSON
	my $decoded_json = decode_json($json);

	my $json_obj = from_json($json);

	for my $item ( @{ $decoded_json->{downloads} } ) {

		foreach ( $item->{description} ) {
			if (/$searchString/) {
				return $item->{zipUrl};
			}
		}
	}
}

sub getBooleanInput {
	my $LOOP = 1;
	my $input;

	while ( $LOOP == 1 ) {

		$input = <STDIN>;
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

sub getGenericInput {
	my $input;

	$input = <STDIN>;
	chomp $input;

	if ( $input eq "" ) {
		return "default";
	}
	else {
		return $input;
	}
}

sub genConfigItem{
	my $mode;
	my $cfg;
	my $configParam;
	my $messageText;
	my $defaultInputValue;
	my $defaultValue;
	my $input;
	
	$mode = $_[0];
    $cfg = $_[1];
    $configParam = $_[2];
    $messageText = $_[3];
    $defaultInputValue = $_[4];
    
    
	if ( $mode eq "UPDATE" ) {
		if ( $cfg->param($configParam) ) {
			$defaultValue = $cfg->param($configParam);
		}
		else {
			$defaultValue = $defaultInputValue;
		}
	}
	else {
		$defaultValue = $defaultInputValue;;
	}
	print "\n\n". $messageText ." ["
	  . $defaultValue . "]: ";

	$input = getGenericInput();
	if ( $input eq "default" )
	{
		$cfg->param( $configParam, $defaultValue );
	}
	else
	{
		$cfg->param( $configParam, $input );
	}
	
}

########################################
#LoadSuiteConfig                       #
########################################
sub loadSuiteConfig {
	if ( -e "new.cfg" ) {
		$globalConfig = new Config::Simple('new.cfg');
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
    $cfg = $_[1];
	
	genConfigItem($mode, $cfg, "jira.installDir", "Please enter the directory Jira will be installed into.", $cfg->param("general.rootInstallDir") . "/jira");
	genConfigItem($mode, $cfg, "jira.dataDir", "Please enter the directory Jira's data will be stored in.", $cfg->param("general.rootDataDir") . "/jira");
    genConfigItem($mode, $cfg, "jira.connectorPort", "Please enter the Connector port Jira will run on (note this is the port you will access in the browser).", "8080");
	genConfigItem($mode, $cfg, "jira.serverPort", "Please enter the SERVER port Jira will run on (note this is the control port not the port you access in a browser).", "8000");
	genConfigItem($mode, $cfg, "jira.javaParams", "Enter any additional paramaters you would like to add to the Java RUN_OPTS.", "");

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
    $cfg = $_[1];
	
	genConfigItem($mode, $cfg, "crowd.installDir", "Please enter the directory Crowd will be installed into.", $cfg->param("general.rootInstallDir") . "/crowd");
	genConfigItem($mode, $cfg, "crowd.dataDir", "Please enter the directory Crowd's data will be stored in.", $cfg->param("general.rootDataDir") . "/crowd");
    genConfigItem($mode, $cfg, "crowd.connectorPort", "Please enter the Connector port Crowd will run on (note this is the port you will access in the browser).", "8095");
	genConfigItem($mode, $cfg, "crowd.serverPort", "Please enter the SERVER port Crowd will run on (note this is the control port not the port you access in a browser).", "8000");
	genConfigItem($mode, $cfg, "crowd.javaParams", "Enter any additional paramaters you would like to add to the Java RUN_OPTS.", "");

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
    $cfg = $_[1];
	
	genConfigItem($mode, $cfg, "fisheye.installDir", "Please enter the directory Fisheye will be installed into.", $cfg->param("general.rootInstallDir") . "/fisheye");
	genConfigItem($mode, $cfg, "fisheye.dataDir", "Please enter the directory Fisheye's data will be stored in.", $cfg->param("general.rootDataDir") . "/fisheye");
	genConfigItem($mode, $cfg, "fisheye.serverPort", "Please enter the SERVER port Fisheye will run on.", "8060");
	genConfigItem($mode, $cfg, "fisheye.javaParams", "Enter any additional paramaters you would like to add to the Java RUN_OPTS.", "");


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
    $cfg = $_[1];
	
	genConfigItem($mode, $cfg, "confluence.installDir", "Please enter the directory Confluence will be installed into.", $cfg->param("general.rootInstallDir") . "/confluence");
	genConfigItem($mode, $cfg, "confluence.dataDir", "Please enter the directory Confluence's data will be stored in.", $cfg->param("general.rootDataDir") . "/confluence");
    genConfigItem($mode, $cfg, "confluence.connectorPort", "Please enter the Connector port Confluence will run on (note this is the port you will access in the browser).", "8090");
	genConfigItem($mode, $cfg, "confluence.serverPort", "Please enter the SERVER port Confluence will run on (note this is the control port not the port you access in a browser).", "8000");
	genConfigItem($mode, $cfg, "confluence.javaParams", "Enter any additional paramaters you would like to add to the Java RUN_OPTS.", "");


}

########################################
#Download Atlassian Installer          #
########################################
sub downloadAtlassianInstaller{
	my $type;
	my $product;
    my $version;
    my $downloadURL;
    my $architecture;
    my $parsedURL;
    my $i;
    
    
    $type = $_[0];
    $product = $_[1];
    $version = $_[2];
    $architecture = $_[3];
	
	if ($type eq "LATEST"){
		$downloadURL = getLatestDownloadURL($product, $architecture);
	}


    $parsedURL = URI->new($downloadURL);
    my @bits = $parsedURL->path_segments();
    $ua->show_progress(1);

	getstore($downloadURL, $globalConfig->param("general.rootInstallDir") . "/" . $bits[@bits-1]);


}

########################################
#GenerateSuiteConfig                   #
########################################
sub generateSuiteConfig {
	my $cfg;
	my $mode;
	my $input;
	my $defaultValue;

	if ($globalConfig) {
		$mode = "UPDATE";
		$cfg  = $globalConfig;
	}
	else {
		$mode = "NEW";
		$cfg = new Config::Simple( syntax => 'ini' );
	}

	print
"This will guide you through the generation of the config required for the management of the Atlassian suite.";

	if ( testOSArchitecture() eq "64" ) {
		if ( $mode eq "UPDATE" ) {
			if ( $globalConfig->param("general.force32Bit") ne "TRUE" ) {
				$defaultValue = "no";
			}
			else {
				$defaultValue = "yes";
			}
		}
		else {
			$defaultValue = "no";
		}
		print "\n\nYour operating system architecture has been detected as "
		  . testOSArchitecture()
		  . "bit. Would you prefer to override this and force 32 bit installs (not recommended)? yes/no ["
		  . $defaultValue . "]: ";

		$input = getBooleanInput();
		if ( $input eq "yes"
			|| ( $input eq "default" && $defaultValue eq "yes" ) )
		{
			$cfg->param( "general.force32Bit", "TRUE" );
		}
		elsif ( $input eq "no"
			|| ( $input eq "default" && $defaultValue eq "no" ) )
		{
			$cfg->param( "general.force32Bit", "FALSE" );
		}

	}

	if ( $mode eq "UPDATE" ) {
		if ( $globalConfig->param("general.rootInstallDir") ) {
			$defaultValue = $globalConfig->param("general.rootInstallDir");
		}
		else {
			$defaultValue = "/opt/atlassian";
		}
	}
	else {
		$defaultValue = "/opt/atlassian";
	}
	print "\n\nPlease enter the root directory the suite will be installed into. ["
	  . $defaultValue . "]: ";

	$input = getGenericInput();
	if ( $input eq "default" )
	{
		$cfg->param( "general.rootInstallDir", $defaultValue );
	}
	else
	{
		$cfg->param( "general.rootInstallDir", $input );
	}
	
		if ( $mode eq "UPDATE" ) {
		if ( $globalConfig->param("general.rootDataDir") ) {
			$defaultValue = $globalConfig->param("general.rootDataDir");
		}
		else {
			$defaultValue = "/var/atlassian/application-data";
		}
	}
	else {
		$defaultValue = "/var/atlassian/application-data";
	}
	print "\n\nPlease enter the root directory the suite data/home directories will be stored. ["
	  . $defaultValue . "]: ";

	$input = getGenericInput();
	if ( $input eq "default" )
	{
		$cfg->param( "general.rootDataDir", $defaultValue );
	}
	else
	{
		$cfg->param( "general.rootDataDir", $input );
	}

	if ( $mode eq "UPDATE" ) {
		if ( $globalConfig->param("crowd.enable") ne "TRUE" ) {
			$defaultValue = "no";
		}
		else {
			$defaultValue = "yes";
		}
	}
	else {
		$defaultValue = "yes";
	}

	print "\n\nDo you wish to install/manage Crowd? yes/no ["
	  . $defaultValue . "]: ";
	$input = getBooleanInput();
	if ( $input eq "yes" || ( $input eq "default" && $defaultValue eq "yes" ) )
	{
		$cfg->param( "crowd.enable", "TRUE" );
		generateCrowdConfig($mode, $cfg);
	}
	elsif ( $input eq "no" || ( $input eq "default" && $defaultValue eq "no" ) )
	{
		$cfg->param( "crowd.enable", "FALSE" );
	}

	if ( $mode eq "UPDATE" ) {
		if ( $globalConfig->param("jira.enable") ne "TRUE" ) {
			$defaultValue = "no";
		}
		else {
			$defaultValue = "yes";
		}
	}
	else {
		$defaultValue = "yes";
	}

	print "\n\nDo you wish to install/manage JIRA? yes/no ["
	  . $defaultValue . "]: ";
	$input = getBooleanInput();
	if ( $input eq "yes" || ( $input eq "default" && $defaultValue eq "yes" ) )
	{
		$cfg->param( "jira.enable", "TRUE" );
		generateJiraConfig($mode, $cfg);
	}
	elsif ( $input eq "no" || ( $input eq "default" && $defaultValue eq "no" ) )
	{
		$cfg->param( "jira.enable", "FALSE" );
	}

	if ( $mode eq "UPDATE" ) {
		if ( $globalConfig->param("confluence.enable") ne "TRUE" ) {
			$defaultValue = "no";
		}
		else {
			$defaultValue = "yes";
		}
	}
	else {
		$defaultValue = "yes";
	}

	print "\n\nDo you wish to install/manage Confluence? yes/no ["
	  . $defaultValue . "]: ";
	$input = getBooleanInput();
	if ( $input eq "yes" || ( $input eq "default" && $defaultValue eq "yes" ) )
	{
		$cfg->param( "confluence.enable", "TRUE" );
		generateConfluenceConfig($mode, $cfg);
	}
	elsif ( $input eq "no" || ( $input eq "default" && $defaultValue eq "no" ) )
	{
		$cfg->param( "confluence.enable", "FALSE" );
	}

	if ( $mode eq "UPDATE" ) {
		if ( $globalConfig->param("fisheye.enable") ne "TRUE" ) {
			$defaultValue = "no";
		}
		else {
			$defaultValue = "yes";
		}
	}
	else {
		$defaultValue = "yes";
	}

	print "\n\nDo you wish to install/manage Fisheye? yes/no ["
	  . $defaultValue . "]: ";
	$input = getBooleanInput();
	if ( $input eq "yes" || ( $input eq "default" && $defaultValue eq "yes" ) )
	{
		$cfg->param( "fisheye.enable", "TRUE" );
		generateFisheyeConfig($mode, $cfg);
	}
	elsif ( $input eq "no" || ( $input eq "default" && $defaultValue eq "no" ) )
	{
		$cfg->param( "fisheye.enable", "FALSE" );
	}
	$cfg->write("new.cfg");
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
loadSuiteConfig();
#generateSuiteConfig();
downloadAtlassianInstaller("LATEST", "confluence", "", whichApplicationArchitecture());