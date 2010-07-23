## @file
# This file contains the implementation of a compact, simple congifuration
# loading and saving class.
#
# @author  Chris Page &lt;chris@starforge.co.uk&gt;
# @version 2.0
# @date    22 Feb 2009
# @copy    2009, Chris Page &lt;chris@starforge.co.uk&gt;
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

## @class ConfigMicro
# A simple configuration class intended to allow ini files to be read and saved. This
# provides the means to read the contents of an ini file into a hash and saving such a
# hash out as an ini file.
#
# @par Example
#
# Given an ini file of the form
# <pre>[sectionA]
# keyA = valueA
# keyB = valueB
#
# [sectionB]
# keyA = valueC
# keyC = valueD</pre>
# this will load the file into a hash of the form
# <pre>{ "sectionA" => { "keyA" => "valueA",
#                   "keyB" => "valueB" },
#   "sectionB" => { "keyA" => "valueC",
#                   "keyC" => "valueD" } 
# }</pre>
package ConfigMicro;

require 5.005;
use DBI;
use strict;

our ($VERSION, $errstr);

BEGIN {
	$VERSION = 1.2;
	$errstr = '';
}

# ============================================================================
#  Constructor and basic file-based config functions

# Create an empty object
sub new { bless {}, shift }

# Read a configuration file into a hash.
sub read 
{
    my $self     = shift;
    my $filename = shift or return set_error("No file name provided");

    my $config;
    my $section = "_";

    if(!open(CFILE, "< $filename")) {
        return set_error("Failed to open '$filename': $!");
    } 

    my $counter = 0;
    while(my $line = <CFILE>) {
        chomp($line);
        ++$counter;

        # Skip comments 
        next if($line =~ /^\s*(?:\#|\;)/ || $line =~ /^\s*$/);

		# Handle section headers
        if($line =~ /^\s*\[(.+?)\]\s*/) {
            $section = $1;

        # Handle attributes
		} elsif($line =~ /^\s*([\w\-]+)\s*=\s*(.*)$/ ) {
			$config -> {$section} -> {$1} = $2;

        # bad input...
		} else {
            close(CFILE);
            return set_error("Syntax error on line $counter: '$line'");
        }
	}

    close(CFILE);

    # set to 1 if the settings are modified..
    $config -> {modified} = 0 if($config);

    return $config;
}


# returs a text version of the configuration
sub text_config {
    my $self     = shift;
    my $config = shift;
    my $result;

    my ($key, $skey);
    foreach $key (sort keys %$config) {
        next if($key eq "modified");
 
        $result .= "[$key]\n" if($key ne "_");

        my $section = $config -> {$key};
        foreach $skey (sort keys %$section) {
            $result .= $skey." = ".$config -> {$key} -> {$skey}."\n";
        }
        $result .= "\n";
    }
    return $result;
}


# Save a configuration hash to a file.
sub save 
{
    my $self     = shift;
    my $filename = shift or return set_error("No file name provided");
    my $config   = shift or return set_error("No configuration hashref provided");

    # Do nothing if the config has not been modified.
    return 0 if(!$config -> {modified});

    if(!open(CFILE, "> $filename")) {
        return set_error("Failed to save '$filename': $!");
    } 

    print CFILE $self -> text_config($config);

    close(CFILE);

    return $config;
}

# ============================================================================
#  Error functions

sub error { return $errstr; }

sub set_error { $errstr = shift; return undef; }

1;
