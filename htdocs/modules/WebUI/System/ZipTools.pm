## @file
# This file contains the implementation of the zip handling interface.
#
# @author  Chris Page &lt;chris@starforge.co.uk&gt;
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

## @class
# A convenience class to make invocation of the course zip tools easier.
# This allows the zip process to be invoked in the background, allowing
# very large courses to be zipped without blocking the webapp.
package WebUI::System::ZipTools;

use strict;
use base qw(Webperl::SystemModule);
use Webperl::Utils qw(untaint_path path_join read_pid);

# ============================================================================
#  Constructor

## @cmethod ZipTools new(@args)
# Create a new ZipTools object
#
# @param args A hash of key, value pairs to initialise the object with.
# @return     A reference to a new ZipTools object.
sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;
    my $self     = $class -> SUPER::new(@_)
        or return undef;

    return $self;
}


# =============================================================================
#  Zip interface

## @fn void launch_zip($pidfile)
# Start the zip script to pack the course into a zip file the user can download.
# Note that this will start the zip process in the background with nohup to
# avoid blocking the webapp during compression.
#
# @param pidfile
sub launch_zip {
    my $self = shift;
    my $pidfile = shift || untaint_path(path_join($self -> {"settings"} -> {"config"} -> {"work_path"}, $self -> {"session"} -> {"sessid"}, "zipwrapper.pid"));

    my $cname = $self -> {"session"} -> get_variable('course');
    my ($name) = $cname =~ /^(\w+)$/;

    my $sessid = $self -> {"session"} -> {"sessid"};
    my ($sid) = $sessid =~ /^([a-fA-F0-9]{32})$/;

    # Create the command to launch the zippery
    my $cmd = $self -> {"settings"} -> {"paths"} -> {"nohup"}." ".$self -> {"settings"} -> {"config"} -> {"base"}."/supportfiles/zipcourse.pl".
        " $sid $name".
        " > $pidfile".
        ' 2>&1 &';

    # Start it going...
    `$cmd`;
}


## @fn $ check_zip($pidfile)
# Determine whether the zip wrapper is currently working. This will determine whether the
# wrapper process is still alive, and return true if it is.
#
# @param pidfile Optional PID file to load, if not specified the session default file is used.
# @return true if the exporter is running, false otherwise.
sub check_zip {
    my $self    = shift;
    my $pidfile = shift || untaint_path(path_join($self -> {"settings"} -> {"config"} -> {"work_path"}, $self -> {"session"} -> {"sessid"}, "zipwrapper.pid"));

    # Does the pid file even exist? If not don't bother doing anything
    return 0 if(!-f $pidfile);

    # It exists, so we need to load it and see if the process is running
    my $pid = read_pid($pidfile);

    # check whether it's possible to signal the process
    return $pid if(kill 0, $pid);

    return undef;
}


## @fn $ halt_zip()
# Determine whether the zip wrapper is still working, and if it is kill it. This will
# attempt to load the PID file for the zip wrapper, and kill the process specified in
# it if the process is running, otherwise it will simply delete the file.
#
# @return true if the zip system was running and has been killed, false otherwise.
sub halt_zip {
    my $self    = shift;
    my $pidfile = shift || untaint_path(path_join($self -> {"settings"} -> {"config"} -> {"work_path"}, $self -> {"session"} -> {"sessid"}, "zipwrapper.pid"));

    # Is the zip process still going?
    my $pid = $self -> check_zip($pidfile);

    # Remove the no-longer-needed pid file
    unlink($pidfile);

    # If the process is running, try to kill it
    # We could probably use TERM rather than KILL, but this can't be blocked...
    return kill 9,$pid if($pid);

    return 0;
}

1;