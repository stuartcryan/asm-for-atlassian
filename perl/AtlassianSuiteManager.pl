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
use JSON qw( decode_json );    # From CPAN
use JSON qw( from_json );      # From CPAN
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
#Get the latest URL to download XXX    #
########################################
sub getLatestDownloadURL {
	my $versionurl =
	  "https://my.atlassian.com/download/feeds/current/" . $ARGV[0] . ".json";
	my $searchString;

	if ( $ARGV[0] eq "confluence" ) {
		$searchString = ".*Linux.*$ARGV[1].*";
	}
	elsif ( $ARGV[0] eq "jira" ) {
		$searchString = ".*Linux.*$ARGV[1].*";
	}
	elsif ( $ARGV[0] eq "stash" ) {
		$searchString = ".*TAR.*";
	}
	elsif ( $ARGV[0] eq "fisheye" ) {
		$searchString = ".*FishEye.*";
	}
	elsif ( $ARGV[0] eq "crowd" ) {
		$searchString = ".*TAR.*";
	}
	elsif ( $ARGV[0] eq "bamboo" ) {
		$searchString = ".*TAR\.GZ.*";
	}
	else {
		print "That package is not recognised - Really you should never get here so if you managed to *wavesHi*";
		exit 2;
	}

	my $json = get $versionurl ;

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
				print $item->{zipUrl} . "\n";
			}
		}
	}
}

sub getBooleanInput {
	my $LOOP = 1;
	my $input;
	
	while ( $LOOP == 1 ) {

		$input= <STDIN>;
		chomp $input;
		
		
		if (   
			( lc $input ) eq "yes"
			|| ( lc $input ) eq "y" )
		{
			$LOOP = 0;
			return "yes";
		}
		elsif ( ( lc $input ) eq "no" || ( lc $input ) eq "n" ) {
			$LOOP = 0;
			return "no";
		} elsif ($input eq ""){
			$LOOP = 0;
			return "default";
		}
		else {
			print "Your input '" . $input ."'was not recognised. Please try again and write yes or no\n\n";
		}
	}
}

########################################
#GenerateSuiteConfig                   #
########################################
sub loadSuiteConfig {
	if (-e "new.cfg"){
		 $globalConfig = new Config::Simple('new.cfg');
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

	if ($globalConfig){
		 $mode = "UPDATE";
		 $cfg = $globalConfig;
	} else {
		$mode = "NEW";
		$cfg = new Config::Simple( syntax => 'ini' );
	}
	
	print "This will guide you through the generation of the config required for the management of the Atlassian suite.\n\n";

	if ( testOSArchitecture() eq "64" ) {
		print "Your operating system architecture has been detected as "
		  . testOSArchitecture()
		  . "bit. Would you prefer to override this and force 32 bit installs (not recommended)?";
	}

    if ($mode eq "UPDATE"){
    	if ($globalConfig->param("crowd.enable") ne "ENABLED" ){
    		$defaultValue = "no";
    	} else {
    		$defaultValue = "yes";
    	}
    } else {
    	$defaultValue = "yes";
    }
    
	print "\n\nDo you wish to install/manage Crowd? yes/no [". $defaultValue ."]";
	$input = getBooleanInput();
	if ( $input eq "yes" || ($input eq "default" && $defaultValue eq "yes"))
	{
		$cfg->param( "crowd.enable", "ENABLED" );
	}
	elsif ( $input eq "no" || ($input eq "default" && $defaultValue eq "no")) {
		$cfg->param( "crowd.enable", "DISABLED" );
	}

    if ($mode eq "UPDATE"){
    	if ($globalConfig->param("jira.enable") ne "ENABLED" ){
    		$defaultValue = "no";
    	} else {
    		$defaultValue = "yes";
    	}
    } else {
    	$defaultValue = "yes";
    }
    
	print "\n\nDo you wish to install/manage JIRA? yes/no [". $defaultValue ."]";
	$input = getBooleanInput();
	if ( $input eq "yes" || ($input eq "default" && $defaultValue eq "yes"))
	{
		$cfg->param( "jira.enable", "ENABLED" );
	}
	elsif ( $input eq "no" || ($input eq "default" && $defaultValue eq "no")) {
		$cfg->param( "jira.enable", "DISABLED" );
	}

    if ($mode eq "UPDATE"){
    	if ($globalConfig->param("confluence.enable") ne "ENABLED" ){
    		$defaultValue = "no";
    	} else {
    		$defaultValue = "yes";
    	}
    } else {
    	$defaultValue = "yes";
    }
    
	print "\n\nDo you wish to install/manage Confluence? yes/no [". $defaultValue ."]";
	$input = getBooleanInput();
	if ( $input eq "yes" || ($input eq "default" && $defaultValue eq "yes"))
	{
		$cfg->param( "confluence.enable", "ENABLED" );
	}
	elsif ( $input eq "no" || ($input eq "default" && $defaultValue eq "no")) {
		$cfg->param( "confluence.enable", "DISABLED" );
	}

    if ($mode eq "UPDATE"){
    	if ($globalConfig->param("fisheye.enable") ne "ENABLED" ){
    		$defaultValue = "no";
    	} else {
    		$defaultValue = "yes";
    	}
    } else {
    	$defaultValue = "yes";
    }
    
	print "\n\nDo you wish to install/manage Fisheye? yes/no [". $defaultValue ."]";
	$input = getBooleanInput();
	if ( $input eq "yes" || ($input eq "default" && $defaultValue eq "yes"))
	{
		$cfg->param( "fisheye.enable", "ENABLED" );
	}
	elsif ( $input eq "no" || ($input eq "default" && $defaultValue eq "no")) {
		$cfg->param( "fisheye.enable", "DISABLED" );
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
generateSuiteConfig();
