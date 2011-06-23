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
use MediaWiki::API;
use Pod::Usage;
use XML::Simple;

# Local modules
use lib ("$path/modules"); # Add the script path for module loading
use Logger;
use ProcessorVersion;
use Utils qw(save_file path_join find_bin write_pid get_password makedir load_config);
use MediaWiki::Wrap;

# Location of the API script in the default wiki.
use constant WIKIURL    => 'http://elearn.cs.man.ac.uk/devwiki/api.php';

# Location of the Special:Upload page in the wiki
use constant UPLOADURL  => 'http://elearn.cs.man.ac.uk/devwiki/index.php/Special:Upload';

# default settings
my %default_config = ( course_page   => "Course",
                       data_page     => "coursedata",
                       themes_title  => "Themes",
                       modules_title => "Modules",
                       metadata      => "Metadata",
                       media_page    => "Media"
    );

# various globals set via the arguments
my ($coursedir, $username, $password, $namespace, $apiurl, $uploadurl, $verbose, $configfile, $pidfile, $quiet) = ('', '', '', '', WIKIURL, UPLOADURL, 0, '', '', 0);
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


# -----------------------------------------------------------------------------
#  Scanning functions






# -----------------------------------------------------------------------------
#  Interesting Stuff

binmode STDOUT, ':utf8';

# This will store all the markers located...
my $markers = { };

# Process the command line
GetOptions('course|c=s'    => \$coursedir,
           'username|u=s'  => \$username,
           'password|p=s'  => \$password,
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

}
