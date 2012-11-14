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
use strict;                    # Good practice
use warnings;                  # Good practice

########################################
#Set Up Variables                      #
########################################


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

########################################
#Display Install Menu                  #
########################################
testOSArchitecture();