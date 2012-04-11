# @file utils.pl
# General utility functions. This file contains the implementation of
# functions used throughout the processor and support tools.
#
# @copy 2011, Chris Page &lt;chris@starforge.co.uk&gt;
# @version 2.5

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
package MCPUtils;

use Exporter;
use ConfigMicro;
use File::Spec;
use File::Path;
use strict;

our @ISA       = qw(Exporter);
our @EXPORT    = qw();
our @EXPORT_OK = qw(get_password makedir load_config);
our $VERSION   = 2.1;

## @fn $ get_password()
# Obtain a password from the user. This will read the user's password
# from STDIN after prompting for input, and disabling terminal echo. Once
# the password has been entered, echo is re-enabled. If no password is
# entered, this will die and not return.
#
# @return A string containing the user's password.
sub get_password {
    my ($word, $tries) = ("", 0);

    # We could do something fancy with Term::ReadChar or something, but this
    # code is pretty much tied to *nix anyway, so just use stty...
    system "stty -echo";

    # repeat until we get a word, or the user presses return three times.
    while(!$word && ($tries < 3)) {
        print STDERR "Password: ";  # print to stderr to avoid issues with output redirection.
        chomp($word = <STDIN>);
        print STDERR "\n";
        ++$tries;
    }
    # Remember to reinstate the echo...
    system "stty echo";

    # Bomb if the user has just pressed return
    die "FATAL: No password provided\n" if(!$word);

    # Otherwise send back the string
    return $word;
}


## @fn $ makedir($name, $logger, $no_warn_exists)
# Attempt to create the specified directory if needed. This will determine
# whether the directory exists, and if not whether it can be created.
#
# @param name           The name of the directory to create.
# @param logger         A reference to a logger object.
# @param no_warn_exists If true, no warning is generated if the directory exists.
# @return true if the directory was created, false otherwise.
sub makedir {
    my $name           = shift;
    my $logger         = shift;
    my $no_warn_exists = shift;

    # If the directory exists, we're okayish...
    if(-d $name) {
        $logger -> print($logger -> WARNING, "Dir $name exists, the contents will be overwritten.")
            unless($no_warn_exists);
        return 1;

    # It's not a directory, is it something... else?
    } elsif(-e $name) {
        # It exists, and it's not a directory, so we have a problem
        die "FATAL: dir $name corresponds to a file or other resource.\n";

    # Okay, it doesn't exist in any form, time to make it
    } else {
        eval { mkpath($name); };

        if($@) {
            die "FATAL: Unable to create directory $name: $@\n";
        }
        return 1;
    }

    return 0;
}


## @fn $ load_config($configfile, $defaultcfg, $cfgkey, $logger)
# Attempt to load the processor configuration file. This will attempt to load the
# specified configuration file, and if no filename is specified it will attempt
# to load the .courseprocessor.cfg file from the user's home directory.
#
# @param configfile Optional filename of the configuration to load. If this is not
#                   given, the configuration is loaded from the user's home directory.
# @param defaultcfg A reference to the default settings.
# @param cfgkey     The name of the key the default settings apply to.
# @param logger     A reference to a logger object
# @return A reference to a configuration object, or undef if the configuration can
#         not be loaded.
sub load_config {
    my $configfile = shift;
    my $defaultcfg = shift;
    my $cfgkey     = shift;
    my $logger     = shift;
    my $data;

    # If we have no filename specified, we need to look at the user's
    # home directory for the file instead
    if(!$configfile || !-f $configfile) {
        my $home = File::HomeDir -> my_home;
        $configfile = path_join($home, ".courseprocessor.cfg");
    }

    # Get configmicro to load the configuration
    $data = ConfigMicro -> new($configfile)
        if(-f $configfile);

    # we /need/ a data object here...
    if(!$data) {
        $logger -> print($logger -> WARNING, "Unable to load configuration file: ".$ConfigMicro::errstr);
        $data = {};
    } else {
        $logger -> print($logger -> DEBUG, "Loaded configuration from $configfile");
    }

    # Set important defaults if needed
    foreach my $key (keys(%{$defaultcfg})) {
        $data -> {$cfgkey} -> {$key} = $defaultcfg -> {$key} if(!$data -> {$cfgkey} -> {$key});
    }

    return $data;
}

1;
