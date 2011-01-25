## @file
# This file contains the implementation of a simple logging system for 
# the processor.
#
# @author  Chris Page &lt;chris@starforge.co.uk&gt;
# @version 2.0
# @date    16 Aug 2010
# @copy    2009, Chris Page &lt;chris@starforge.co.uk&gt;
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

## @class Logger
# A class to handle logging operations throughout the processor. This collects
# together the various functions needed for displaying log messages and errors
# at various levels of verbosity, in an attempt to cut down on duplicate 
# parameter passing throughout the rest of the system.
#
package Logger;

use strict;

use constant WARNING       => 0;
use constant NOTICE        => 1;
use constant DEBUG         => 2;
use constant MAX_VERBOSITY => 2;

# ============================================================================
#  Constructor
#

## @cmethod $ new(%args)
# Create a new Logging object for use around the system. This creates an object
# that provides functions for printing or storing log information during script
# execution. Meaningful options for this are:
#
# verbosity   - One of the verbosity level constants, any messages over this will
#               not be printed. If this is not specified, it defaults to DEBUG
#               (the highest supported verbosity)
# fatalblargh - If set to true, any calls to the blargh function kill the 
#               script immediately, otherwise blarghs produce warning messages.
#               Defaults to false.
#
# @param args A hash of key, value pairs with which to initialise the object.
# @return A new Logging object.
sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;

    my $self = { 
        "verbosity"   => DEBUG,
        "fatalblargh" => 0,
        "outlevels"   => [ "WARNING", "NOTICE", "DEBUG" ],
        @_,
    };

    return bless $self, $class;
}


## @method void set_verbosity($newlevel)
# Set the verbosity level of this logging object to the specified level. If the
# newlevel argument is not specified, or it is out of range, the object is set
# to the maximum supported verbosity.
#
# @param newlvel The new verbosity level for this logger.
sub set_verbosity {
    my $self     = shift;
    my $newlevel = shift;

    $newlevel = MAX_VERBOSITY if(!defined($newlevel) || $newlevel < 0 || $newlevel > MAX_VERBOSITY);

    $self -> {"verbosity"} = $newlevel;
}


# ============================================================================
#  log printing
#

## @method $ fatal_setting($newstate)
# Get (and optionally set) the value that determines whether calls to blargh
# are fatal. If newstate is provided, the current state of blargh severity is
# set to the new state. 
#
# @param newstate If specified, change the value that determines whether calls
#                 to blargh are fatal: if set to true, calls to blargh will exit 
#                 the script immediately with an error, if set to 0 calls to 
#                 blargh will generate warning messages.
# @return The current state of blargh fatality.
sub fatal_setting {
    my $self     = shift;
    my $newstate = shift;

    $self -> {"fatalblargh"} = $newstate if(defined($newstate));

    return $self -> {"fatalblargh"};
}


## @method void print($level, $message, $newline)
# If the specified level is less than, or equal to, the current verbosity level,
# print the specified message to stdout. If the level is over the verbosity 
# level the message is discarded.
#
# @param level   The level of the message, should be one of WARNING, NOTICE, or DEBUG.
# @param message The message to print.
# @param newline Print a newline after the message. If set to falce, this will suppress
#                the automatic addition of a newline after the message (although the
#                message may still contain its own newlines). If set to true, or omitted,
#                a newline is printed after the message.
sub print {
    my $self      = shift;
    my $level     = shift;
    my $message   = shift;
    my $newline   = shift;

    $newline = 1 if(!defined($newline));

    print $self -> {"outlevels"} -> [$level],": $message",($newline ? "\n" : "")
        if($level <= $self -> {"verbosity"});
}


## @method void blargh($message)
# Generate a message indicating that a serious problem has occurred. If the logging
# object is set up such that blargh()s are fatal, this function will die with the 
# specified message, otherwise the message will be printed as a warning.
#
# @param message The message to print.
sub blargh {
    my $self    = shift;
    my $message = shift; 

    if($self -> {"fatalblargh"}) { 
        die "FATAL: $message\n"; 
    } else { 
        $self -> print(WARNING, $message); 
    } 
}

1;
