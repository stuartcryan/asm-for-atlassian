#!/usr/bin/perl

use LWP::Simple;               # From CPAN
use JSON qw( decode_json );    # From CPAN
use JSON qw( from_json );
use Data::Dumper;              # Perl core module
use strict;                    # Good practice
use warnings;                  # Good practice

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
	print "That package is not recognised";
	exit 2;
}

# 'get' is exported by LWP::Simple; install LWP from CPAN unless you have it.
# You need it or something similar (HTTP::Tiny, maybe?) to get web pages.
my $json = get $versionurl ;

die "Could not get $versionurl!" unless defined $json;

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
