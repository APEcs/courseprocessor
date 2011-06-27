#!/usr/bin/perl -W

## @file
# Script to convert an APEcs/PEVEit course generated using previous
# versions of the course processor into a form suitable for importing
# into a wiki.
#
# For full documentation please see http://elearn.cs.man.ac.uk/devwiki/index.php/Docs:Course2wiki.pl
#
# @copy 2011, Chris Page &lt;chris@starforge.co.uk&gt;
# @version 1.0.0 (22 June 2011)
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

use strict;
use utf8;

use FindBin;             # Work out where we are
my $path;
BEGIN {
    # $FindBin::Bin is tainted by default, so we need to fix that
    if ($FindBin::Bin =~ /(.*)/) {
        $path = $1;
    }
}

use File::HomeDir;
use File::Path;
use Getopt::Long;
use HTML::TreeBuilder;
use MediaWiki::API;
use Pod::Usage;
use Term::ANSIColor;
use XML::Simple;

# Local modules
use lib ("$path/modules"); # Add the script path for module loading
use Logger;
use ProcessorVersion;
use Utils qw(load_file path_join find_bin write_pid get_password makedir load_config);
use MediaWiki::Wrap;

# Location of the API script in the default wiki.
use constant WIKIURL    => 'http://elearn.cs.man.ac.uk/devwiki/api.php';

# Location of the Special:Upload page in the wiki
use constant UPLOADURL  => 'http://elearn.cs.man.ac.uk/devwiki/index.php/Special:Upload';

# How long should the user have to abort the process?
use constant ABORT_TIME => 5;

# default settings
my $default_config = { course_page   => "Course",
                       data_page     => "coursedata",
                       themes_title  => "Themes",
                       modules_title => "Modules",
                       metadata      => "Metadata",
                       media_page    => "Media"
    };

# various globals set via the arguments
my ($coursedir, $username, $password, $namespace, $dryrun, $force, $apiurl, $uploadurl, $verbose, $configfile, $pidfile, $quiet) = ('', '', '', '', 0, 0, WIKIURL, UPLOADURL, 0, '', '', 0);
my $man = 0;
my $help = 0;

# Global logger. Yes, I know, horrible, but it'd be being passed around /everywhere/ anyway
my $logger = new Logger();

# Likewise with the configuration object.
my $config;


## @fn void warn_die_handler($fatal, @messages)
# A simple handler for warn and die events that changes the normal behaviour of both
# so that they print to STDOUT rather than STDERR.
#
# @param fatal    Should the function call exit rather than carry on as normal?
# @param messages The array of messages passed to the die or warn.
sub warn_die_handler {
    my $fatal = shift;
    my @messages = @_;

    print STDOUT @messages;
    exit 1 if($fatal);
}

# Override default warn and die behaviour to ensure that errors and
# warnings do not end up out-of-order in printed logs.
$SIG{__WARN__} = sub { warn_die_handler(0, @_); };
$SIG{__DIE__}  = sub { warn_die_handler(1, @_); };


# -----------------------------------------------------------------------------
#  Utility functions
#

## @fn void doomsayer()
# Warn the user that they have started the script without the dry-run option
# and without the force option, and give them ABORT_TIME seconds to abort the
# process.
sub doomsayer {

    # Print out a friendly, happy warning message
    print colored("-= WARNING * WARNING * WARNING * WARNING * WARNING * WARNING =-", 'bold red'), "\n\n";
    print         "You have launched course2wiki.pl without the --dry-run option.\n";
    print colored("      THIS SCRIPT WILL MODIFY THE CONTENTS OF THE WIKI!", 'bold yellow'),"\n";
    print         "If you are not certain the import will work. Press Ctrl+C now\nto abort the script and run it with the --dry-run option!\n\nContinuing in: ";

    # Countdown time!
    for(my $sec = ABORT_TIME; $sec > 0; --$sec) {
        print colored("$sec.. ", 'bold red');
        select((select(STDOUT), $| = 1)[0]); # Flush stdout

        sleep(1);
    }

    print "\nStarting course to wiki conversion.\n";
}


## @fn @ load_legacy_metadata($dirname)
# Attempt to load the metadata in the specified directory. During loading, this
# will try to correct the metadata contents to meet the current standard.
#
sub load_legacy_metadata {
    my $dirname = shift;

    # If this fails, the file is probably not readable...
    my $content = load_file(path_join($dirname, "metdata.xml"));
    if(!$content) {
        $logger -> print($logger -> WARNING, "Unable to load metadata in $dirname: $!");
        return (undef, undef);
    }

    # Fix up old xml as much as possible...
    # Correct the naming of the root element if needed
    $content =~ s/metadata/theme/g;

    # Do we need to insert an indexorder attribue into the theme element?
    my ($telem) = $content =~ /(<\s*theme.*?>)/;
    $content =~ s/theme/theme indexorder="1"/ if($telem !~ /indexorder/);
}


# -----------------------------------------------------------------------------
#  Scanning functions

## @fn $ scan_theme_directory($fullpath, $dirname)
# Check whether the specified directory is a theme directory (it contains a
# metadata.xml file) and if it is, process its contents.
sub scan_theme_directory {
    my $fullpath = shift;
    my $dirname  = shift;

    # Do we have a metadata file? If not, give up...
    if(!-f path_join($dirname, "metadata.xml")) {
        $logger -> print($logger -> WARNING, "Skipping non-theme directory $dirname (metadata.xml not found in directory)");
        return undef;
    }

    # load the metadata, converting it as needed
    my ($xmltree, $metadata) = load_legacy_metadata($dirname);
}

# -----------------------------------------------------------------------------
#  Interesting Stuff

binmode STDOUT, ':utf8';

# This will store all the markers located...
my $markers = { };

# Process the command line
GetOptions('course|c=s'    => \$coursedir,
           'username|u=s'  => \$username,
           'password|p=s'  => \$password,
           'dry-run!'      => \$dryrun,
           'force!'        => \$force,
           'wiki|w=s'      => \$apiurl,
           'uploadurl=s'   => \$uploadurl,
           'namespace|n=s' => \$namespace,
           'config|g=s'    => \$configfile,
           'pid=s'         => \$pidfile,
           'verbose|v+'    => \$verbose,
           'quiet|q!'      => \$quiet,
           'help|?|h'      => \$help,
           'man'           => \$man) or pod2usage(2);
if(!$help && !$man) {
    print STDERR "No course directory specified.\n" if(!$coursedir);
}
pod2usage(-verbose => 2) if($man);
pod2usage(-verbose => 0) if($help || !$username);

# Before doing any real work, write the PID if needed.
write_pid($pidfile) if($pidfile);

print "course2wiki.pl version ",get_version("course2wiki")," started.\n";

# set up the logger and configuration data
$logger -> set_verbosity($verbose);
$config = load_config($configfile, $default_config, "wiki2course", $logger);

# Do we have a course directory to work on?
if(-d $coursedir) {
    # predict doom if the program is launched without dry-run and force
    doomsayer() unless($dryrun || $force);

    # If we don't have a password, prompt for it
    $password = get_password() if(!$password);

    # Get the show on the road...
    my $wikih = MediaWiki::API -> new({api_url => $apiurl });

    # Set the upload url if needed
    $wikih -> {"config"} -> {"upload_url"} = $uploadurl if($uploadurl);

    # Now we need to get logged in so we can get anywhere
    wiki_login($wikih, $username, $password);

    # Check the specified namespace is valid
    die "FATAL: The specified namespace does not appear in the wiki. You must create the namespace before it can be used.\n"
        unless(wiki_valid_namespace($wikih, $namespace));

    # Okay, now we hope the course is a course...
    opendir(CDIR, $coursedir)
        or die "FATAL: Unable to open course directory: $!\n";

    my $themelist = "";
    while(my $entry = readdir(CDIR)) {
        # skip anything that isn't a directory for now
        next if($entry =~ /^\.\.?$/ || !(-d path_join($coursedir, $entry)));

        my $themelink = wiki_link(scan_theme_directory(path_join($coursedir, $entry)));
        $themelist .= "$themelink<br />" if($themelink);
    }

    # check for a course index to push into the course metadata
    my $coursemap = extract_coursemap();

    # Finish off the course page as much as possible
    wiki_set_coursedata($themelist, $coursemap);

}

print "Import finished.\n";


# THE END!
__END__
