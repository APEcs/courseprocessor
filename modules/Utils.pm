# Utils - general utility functions

# General utilities package, contains functions common to the
# various handlers.

# @copy 2008, Chris Page &lt;chris@starforge.co.uk&gt;
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

# All plugins must implement the following functions:
#
# get_type        - return "input" or "output"  
# get_description - return a human-readable description of the module 
# new             - return an instance of the module object
# use_plugin      - returns true if th eplugin can be used on the tree, false if not
# process         - actually does the processing.

package Utils;
use Exporter;
use Term::Size;
use Time::Local qw(timelocal);
use File::Spec;
use strict;

our @ISA       = qw(Exporter);
our @EXPORT    = qw();
our @EXPORT_OK = qw(path_join check_directory load_file resolve_path reset_pointprogress update_pointprogress lead_zero);
our $VERSION   = 1.0;


## @fn $ path_join(@fragments)
# Take an array of path fragments and concatenate them together. This will 
# concatenate the list of path fragments provided using '/' as the path 
# delimiter (this is not as platform specific as might be imagined: windows
# will accept / delimited paths). The resuling string is trimmed so that it
# <b>does not</b> end in /, but nothing is done to ensure that the string
# returned actually contains a valid path.
#
# @param fragments The path fragments to join together.
# @return A string containing the path fragments joined with forward slashes.
sub path_join {
    my @fragments = @_;

    my $result = "";

    # We can't easily use join here, as fragments might end in /, which
    # would result in some '//' in the string. This may be slower, but
    # it will ensure there aren't stray slashes around.
    foreach my $fragment (@fragments) {
        $result .= $fragment;
        # append a slash if the result doesn't end with one
        $result .= "/" if($result !~ /\/$/);
    }

    # strip the trailing / if there is one
    return substr($result, 0, length($result) - 1) if($result =~ /\/$/);
    return $result;
}


# Convert a relative (or partially relative) file into a truly absolute path.
# for example, /foo/bar/../wibble/ptang becomes /foo/wibble/ptang and
# /foo/bar/./wibble/ptang becomes /foo/bar/wibble/ptang
sub resolve_path {
    my $path = shift;

    # make sure the path is absolute to begin with
    $path = File::Spec -> rel2abs($path) if($path !~ /^\//);

    my ($vol, $dirs, $file) = File::Spec -> splitpath($path);

    my @dirs = File::Spec -> splitdir($dirs);
    my $i = 0;

    # loop through all the directories removing relative and current entries.
    while($i < scalar(@dirs)) {
        # each time a '..' is encountered, remove it and the preceeding entry from the array.
        if($dirs[$i] eq "..") {
            die "Attempt to normalise a relative path!" if($i == 0);
            splice(@dirs, ($i - 1), 2);
            $i -= 1; # move back one level to account for the removal of the preceeding entry.

        # single '.'s - current dir - can just be stripped without touching previous entries
        } elsif($dirs[$i] eq ".") {
            die "Attempt to normalise a relative path!" if($i == 0);
            splice(@dirs, $i, 1);
            # do not update $i at this point - it will be looking at the directory after the . now.
        } else {
            ++$i;
        }
    }

    return File::Spec -> catpath($vol, File::Spec -> catdir(@dirs), $file);
}

sub check_directory {
    my $dirname  = shift;
    my $type     = shift;
    my $exists   = shift;
    my $nolink   = shift;
    my $checkdir = shift;

    $exists   = 1 if(!defined($exists));
    $nolink   = 0 if(!defined($nolink));
    $checkdir = 1 if(!defined($checkdir));
    
    die "FATAL: The specified $type does not exist"
        unless(!$exists || -e $dirname);

    die "FATAL: The specified $type is a link, please only use real directories"
        if($nolink && -l $dirname);

    die "FATAL: The specified $type is not a directory"
        unless(!$checkdir || -d $dirname);
}

sub load_file {
    my $name = shift;

    if(open(TEMPLATE, $name)) {
        undef $/;
        my $lines = <TEMPLATE>;
        $/ = "\n";
        close(TEMPLATE);

        return $lines;
    }
    return undef;
}


sub lead_zero {
    my $value = shift;

    return "0$value" if($value < 0 && $value !~ /^0/);
    return $value;
}


our $pointcount = 0;

sub reset_pointprogress {
    $pointcount = 0;
}

sub update_pointprogress {
    print ".";
    $pointcount++;

    my ($w,$h) = Term::Size::chars;

    if($w && $pointcount >= $w) {
        print "\n";
        $pointcount = 0;
    }
}

1;
