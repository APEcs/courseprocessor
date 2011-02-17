# @file utils.pl
# General utility functions. This file contains the implementation of 
# functions used throughout the processor and support tools. 
#
# @copy 2010, Chris Page &lt;chris@starforge.co.uk&gt;
# @version 2.1

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

package Utils;
use Exporter;
use Term::Size;
use Time::Local qw(timelocal);
use File::Spec;
use strict;

our @ISA       = qw(Exporter);
our @EXPORT    = qw();
our @EXPORT_OK = qw(path_join check_directory load_file save_file resolve_path superchomp lead_zero string_in_array is_defined_numeric get_proc_size find_bin);
our $VERSION   = 2.1;

## @fn $ path_join(@fragments)
# Take an array of path fragments and concatenate them together. This will 
# concatenate the list of path fragments provided using '/' as the path 
# delimiter. this is not as platform specific as might be imagined: windows
# will accept / delimited paths. The resuling string is trimmed so that it
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
        next if(!defined($fragment) || $fragment eq ''); # Skip empty fragments

        $result .= $fragment;
        # append a slash if the result doesn't end with one
        $result .= "/" if($result !~ /\/$/);
    }

    # strip the trailing / if there is one
    return substr($result, 0, length($result) - 1) if($result =~ /\/$/);
    return $result;
}


## @fn $ resolve_path($path)
# Convert a relative (or partially relative) file into a truly absolute path.
# for example, /foo/bar/../wibble/ptang becomes /foo/wibble/ptang and
# /foo/bar/./wibble/ptang becomes /foo/bar/wibble/ptang
#
# @param path The path to convert to an absolute path
# @return The processed absolute path.
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


## @fn void check_directory($dirname, $title, $options)
# Apply a number of checks to the specified directory. This will check
# various attribues of the specified directory and if any of the checks
# fail, this will die with an appropriate message. If all the checks pass,
# this will return silently. The optional options hash controls which 
# checks are performed on the directory:
#  
# exists    If true, the specified directory must exist. If false, the 
#           existence of the directory is not enforced. If not specified,
#           this check defaults to true. 
# nolink    If true, the directory must be a real, physical directory, it
#           must not be a shambolic link. If false, it can be either. If not
#           specified, this defaults to false (don't check).
# checkdir  If true, verify that the directory is actually a directory and
#           not a file or other special directory entry. If false, don't
#           bother checking. If not specified, this defaults to true.
#
# @note If 'checkdir' is set to true, the function will die with a fatal 
#       error if the directory does not exist even if 'exists' is false.
# @param dirname The directory to check
# @param title   A human-readable description of the directory.
# @param options A reference to a hash of options controlling the checks.      
sub check_directory {
    my $dirname  = shift;
    my $title    = shift;
    my $options  = shift;

    $options -> {"exists"}   = 1 if(!defined($options -> {"exists"}));
    $options -> {"nolink"}   = 0 if(!defined($options -> {"nolink"}));
    $options -> {"checkdir"} = 1 if(!defined($options -> {"checkdir"}));
    
    die "FATAL: The specified $title does not exist.\n"
        unless(!$options -> {"exists"} || -e $dirname);

    die "FATAL: The specified $title is a link, please only use real directories.\n"
        if($options -> {"nolink"} && -l $dirname);

    die "FATAL: The specified $title is not a directory.\n"
        unless(!$options -> {"checkdir"} || -d $dirname);
}


## @fn $ load_file($name)
# Load the contents of the specified file into memory. This will attempt to
# open the specified file and read the contents into a string. This should be
# used for all file reads whenever possible to ensure there are no internal
# problems with UTF-8 encoding screwups.
#
# @param name The name of the file to load into memory.
# @return The string containing the file contents, or undef on error. If this
#         returns undef, $! should contain the reason why.
sub load_file {
    my $name = shift;

    if(open(INFILE, "<:utf8", $name)) {
        undef $/;
        my $lines = <INFILE>;
        $/ = "\n";
        close(INFILE) 
            or return undef;

        return $lines;
    }
    return undef;
}


## @fn $ save_file($name, $data)
# Save the specified string into a file. This will attempt to open the specified
# file and write the string in the second argument into it, and the file will be 
# truncated before writing.  This should be used for all file saves whenever 
# possible to ensure there are no internal problems with UTF-8 encoding screwups.
#
# @param name The name of the file to load into memory.
# @param data The string, or string reference, to save into the file.
# @return undef on success, otherwise this dies with an error message.
# @note This function assumes that the data passed in the second argument is a string,
#       and it does not do any binmode shenanigans on the file. Expect it to break if
#       you pass it any kind of binary data, or use this on Windows.
sub save_file {
    my $name = shift;
    my $data = shift;

    if(open(OUTFILE, ">:utf8", $name)) {
        print OUTFILE ref($data) ? ${$data} : $data;
        
        close(OUTFILE)
            or die "FATAL: Unable to close $name after write: $!\n";

        return undef;
    } 

    die "FATAL: Unable to open $name for writing: $!\n";
}
        

## @fn void superchomp($line)
# Remove any white space or newlines from the end of the specified line. This
# performs a similar task to chomp(), except that it will remove <i>any</i> OS 
# newline from the line (unix, dos, or mac newlines) regardless of the OS it
# is running on. It does not remove unicode newlines (U0085, U2028, U2029 etc)
# because they are made of spiders.
#
# @param line A reference to the line to remove any newline from.
sub superchomp(\$) {
    my $line = shift;

    $$line =~ s/(?:[\s\x{0d}\x{0a}\x{0c}]+)$//o;
}


## @fn $ lead_zero($value)
# Ensure that the specified value starts with 0 if it is less than 10
# and does not already start wiht 0 (so '9' will become '09' but '15'
# will not be altered, nor will '05').
#
# @param value The value to check
# @return The value with a lead 0 if it does not have one already and needs it.
sub lead_zero {
    my $value = shift;

    return "0$value" if($value < 10 && $value !~ /^0/);
    return $value;
}


## @fn $ string_in_array($arrayref, $value)
# Determine whether the specified value exists in an array. This does a simple
# interative serach over the array to determine whether value is present in the
# array.
#
# @param arrayref A reference to the array to search.
# @param value    The value to search for in the array.
# @return The index of the value on success, undef if the value is not in the array.
sub string_in_array {
    my $arrayref = shift;
    my $value    = shift;

    # can't be in an undefined list by definition.
    return undef if(!$arrayref);

    my $size = scalar(@{$arrayref});
    for(my $pos = 0; $pos < $size; ++$pos) {
        return $pos if($arrayref -> [$pos] eq $value);
    }

    return undef;
}


## @fn $ is_defined_numeric($cgi, $param)
# Determine whether the specified cgi parameter is purely numeric and return it
# if it is. If the named parameter is not entirely numeric, this returns undef.
#
# @param cgi   The cgi handle to check the parameter through.
# @param param The name of the cgi parameter to check.
# @return The numeric value in the parameter, or undef if it is not purely numeric.
sub is_defined_numeric {
    my ($cgi, $param) = @_;

    if(defined($cgi -> param($param)) && $cgi -> param($param) !~ /\D/) {
        return $cgi -> param($param);
    }

    return undef;
}


## @fn $ get_proc_size()
# Determine how much memory the current process is using. This examines the process'
# entry in proc, it's not portable, but frankly I don't care less about that.
#
# @return The process virtual size, in bytes, or -1 if it can not be determined.
sub get_proc_size {

    # We don't need no steenking newlines
    my $nl = $/;
    undef $/;

    # Try to open and read the process' stat file
    open(STAT, "/proc/$$/stat")
        or die "Unable to read stat file for current process ($$)\n";
    my $stat = <STAT>;
    close(STAT);

    # Now we need to pull out the vsize field
    my ($vsize) = $stat =~ /^[-\d]+ \(.*?\) \w+ [-\d]+ [-\d]+ [-\d]+ [-\d]+ [-\d]+ [-\d]+ [-\d]+ [-\d]+ [-\d]+ [-\d]+ [-\d]+ [-\d]+ [-\d]+ [-\d]+ [-\d]+ [-\d]+ [-\d]+ [-\d]+ [-\d]+ ([-\d]+)/;

    return $vsize || -1;
}


##@fn $ find_bin($name, $search)
# Attempt to locate the named binary file on the filesystem. This will search several
# standard paths for the named binary (much like the shell will search its path,
# except that this is not subject to environment pollution), and if it is located the
# full path is returned. 
#
# @param name   The name of the binary to locate.
# @param search An optional reference to an array of locations to look in for the 
#               binary. Defaults to ['/usr/bin', '/bin', '/opt/bin', '/usr/local/bin']
#               Paths are searched first to last, and the path of the first matching 
#               binary user can execute is used.
# @return A string containing the path of the binary, or undef on error.
sub find_bin {
    my $name   = shift;
    my $search = shift || ['/usr/bin', '/bin', '/opt/bin', '/usr/local/bin'];

    foreach my $path (@{$search}) {
        my $check = path_join($path, $name);

        return $check if(-f $check && -x $check);
    }

    return undef;
}


1;
