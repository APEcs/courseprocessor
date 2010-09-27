## @class
# A simple class to display a progress bar and associated information on stdout. This 
# class provides a simple terminal-based display of process progress, including
# a percentage display, a bar which fills as the process proceeds, and a numerical
# display of progress. For longer processes, this class also provides the ability
# to display a 'spinner' (a series of characters shown one after the other each time
# the bar is updated) and an ETA display that is capable of displaying estimated
# time to completion from second right up to days. 
package ProgressBar;

use Term::ReadKey;
use Time::HiRes qw(gettimeofday tv_interval);
use strict;

my ($VERSION, @spinner);

BEGIN {
    $VERSION = 1.0;
    @spinner = ('/', '-', '\\', '|');
}

# ============================================================================
#  Constructor

## @cmethod ProgressBar(arg, ...)
# Create a new ProgressBar object. A number of options may be provided as a list
# of key-value pairs. Supported options are:
#
# @arg maxvalue  The value that the bar should consider to be 100% of progress, defaults to 100.
# @arg message   An optional message to show above the bar, defaults to not showing any message.
# @arg spinner   If true a spinner is displayed that will turn a step each time update is called,
#                otherwise no spinner is displayed. Defaults to true.
# @arg eta       If true the estimated time to complete in minutes and seconds is shown, otherwise
#                no ETA is calculated. Defaults to true.
# @arg fillchar  The character to show in filled-in parts of the progress bar. Defaults to '='.
# @arg headchar  The character to show at the head of the progress bar. Defaults to '>'.
# @arg blankchar The character to show in unfilled parts of the progres bar. Defaults to ' '.
# @arg barwidth  If specified, overrides the calculated bar size. Note that setting this may cause
#                the bar to wrap onto the next line of the terminal! Defaults to a width that
#                ensures all the progress bar components will fit on the terminal.
# @arg defwidth  The default terminal width, used if barwidth is not set and the size of the terminal
#                can not be determined at runtime. Set this to 0 if you would prefer the constructor
#                to die() if it can not determine the terminal width when barwidth is not set.
# @arg bytemode  If set to 1 then maxvalue and value are treated as byte values, and the output
#                values are shown in 'human readable' byte/KB/MB/GB format.
sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;

    my $self = {
        'maxvalue'   => 100,
        'message'    => undef,
        'spinner'    => 1,
        'eta'        => 1,
        'fillchar'   => '=',
        'headchar'   => '>',
        'blankchar'  => ' ',
        'defwidth'   => 64, 
        'spinpos'    => 0,
        'updated'    => 0,
        'bytemode'   => 0,
        'forcedraw'  => 0,
        @_,
    };

    # Get the dimensions of the term we're running in if we need to; don't bother if
    # a bar width has been specified.
    my ($cols, $rows, $wpixels, $hpixels) = (0, 0, 0, 0);
    ($cols, $rows, $wpixels, $hpixels) = GetTerminalSize() if(!$self -> {'barwidth'});
    $self -> {'termwidth'} = $cols - 2;

    # If the bar width is not set, and we can't determine the terminal size, either fall
    # back on the default, or die if the default has been zeroed
    if(!$self -> {'barwidth'} && !$cols) {
        die "Unable to get terminal size" if(!$self -> {'defwidth'});
        $self -> {'termwidth'} = $self -> {'defwidth'};
    }

    # calculate how wide the current/value display needs to be 
    if(!$self -> {'bytemode'}) {
        $self -> {'maxwidth'} = length("$self->{'maxvalue'}");
    } else {
        $self -> {'maxwidth'} = 10;
    }
    $self -> {'valwidth'} = 1 + (2 * $self -> {'maxwidth'});

    # The width of the bar itself in characters. The width has to allow space for:
    # 6 characters before the bar, for the percentage display, space and [
    # 2 characters after the bar, for ] and space
    # 2 characters for the spinner IF it is enabled
    # 12 chracters for the eta if it is enabled
    # valwidth characters for the value display
    # Don't override the width if the caller has already set it
    if(!$self -> {'barwidth'}) {
        $self -> {'barwidth'} = $self -> {'termwidth'} - 8 - $self -> {'valwidth'};
        $self -> {'barwidth'} -= 2 if($self -> {'spinner'});
        $self -> {'barwidth'} -= 12 if($self -> {'eta'});
    }

    # Build a string of backspaces which should return the cursor to the spinner pos,
    # if it is needed
    if($self -> {'spinner'}) {
        $self -> {'clearspin'} = "";

        # Remember to add 12 more backspaces if ETA display is enabled!
        my $clearwidth = (2 + $self -> {'valwidth'});
        $clearwidth += 12 if($self -> {'eta'});

        for(my $i = 0; $i < $clearwidth; ++$i) {
            $self -> {'clearspin'} .= "\b";
        }
    }    

    return bless $self, $class;
}


# ============================================================================
#  Public methods


## @method void update($value)
# Update the progress bar to reflect the specified value. If this is called and
# the spinner is <b>disabled</b> then it will only redraw any of the content when
# the percent completed has increased by an integer percentage point or more since
# the previous call. If the spinner is enabled then every call will update the
# spinner, value display, and the ETA if it is enabled. If the value specified
# exceeds the maximum value provided to the constructor it is forced to the 
# maximum.
#
# @param value The value to update the progress bar to. This is capped to the
#              maximum value specified when creating the bar object.
sub update {
    my $self  = shift;
    my $value = shift;

    # limit the value to prevent display corruption
    $value = $self -> {'maxvalue'} if($value > $self -> {'maxvalue'});

    # Calculate what percentage of the process 
    my $percent = int(($value / $self -> {'maxvalue'}) * 100);

    my $fillchars = int(($self -> {'barwidth'} * $percent) / 100);

    # pull the width of the maximum value out of the object for convenience
    my $fieldsize = $self -> {'maxwidth'};

    # fix the spinner if it has overflowed
    $self -> {'spinpos'} = 0 if($self -> {'spinpos'} == scalar(@spinner));

    # calculate eta if needed
    if($self -> {'eta'}) {
        # If we do not have a start time recorded for this bar we must be on the first call,
        # so set the start time and a fill-in ETA.
        if(!$self -> {'started'}) {
            $self -> {'started'} = [ gettimeofday() ];
            $self -> {'etatext'} = ' ETA --m:--s';
        } else {
            # We are some way along the processing, so work out how long this job has 
            # been in progress, and how much is left to do
            my $elapsed = tv_interval($self -> {'started'});
            my $remaining = $self -> {'maxvalue'} - $value;
            
            # Calculate the time per tick of the value, an from that guess how long we have left
            my $secpertick = $elapsed / $value;
            my $timeleft = int($secpertick * $remaining);

            $self -> {'etatext'} = remain_to_eta($timeleft);
        }
    }

    # if this the first run, draw everything should be drawn, including the message
    if(!$self -> {'updated'}) {
        $self -> {'updated'} = 1; # mark the update so we don't do this again

        print $self -> {'message'},"\n" if($self -> {'message'});
    } else {

        # if this is a repeat call, but we have the same number of chars filled as last time,
        # just update the spinner and return
        if(!$self -> {'forcedraw'} && $percent == $self -> {'lastpercent'}) {
            if($self -> {'spinner'}) {
                # move back to where the spinner should be, then print the spinner and status
                print $self -> {'clearspin'}, $spinner[$self -> {'spinpos'}++];
                if(!$self -> {'bytemode'}) {
                    printf " %${fieldsize}d/%${fieldsize}d", $value, $self -> {'maxvalue'};
                } else {
                    printf " %${fieldsize}s/%${fieldsize}s", bytes_to_human($value), bytes_to_human($self -> {'maxvalue'});
                }
                print $self -> {'etatext'} if($self -> {'eta'});
                flush();
            }
            return;
        }
    }

    # If we get here we're doing a full update, so go back to the start of the line...
    print "\r";

    # pre-bar stuff
    printf "%3d%% [", $percent;
    
    # fill in the bar
    for(my $i = 0; $i < $self -> {'barwidth'}; ++$i) {

        # If we're in the filled part of the bar, print the fill character
        if($i < $fillchars) {
            print $self -> {'fillchar'};

        } elsif($i == $fillchars) {
            print $self -> {'headchar'};

        # otherwise print out th eblank char, or a space if on isn't set
        } else {
            print ($self -> {'blankchar'} || " ");
        }
    }

    print "] ";

    # now print out the spinner if needed
    if($self -> {'spinner'}) {
        print $spinner[$self -> {'spinpos'}++], " ";
    }

    # And finally the status and optionally ETA
    if(!$self -> {'bytemode'}) {
        printf " %${fieldsize}d/%${fieldsize}d", $value, $self -> {'maxvalue'};
    } else {
        printf " %${fieldsize}s/%${fieldsize}s", bytes_to_human($value), bytes_to_human($self -> {'maxvalue'});
    }
    print $self -> {'etatext'} if($self -> {'eta'});

    # store the percentage shown in the bar this time around
    $self -> {'lastpercent'} = $percent;
    flush();
}


# ============================================================================
#  Private functions

## @fn private void flush()
# Convenience function to flush stdout without disabling line buffering in 
# general.
sub flush {
    select((select(STDOUT), $| = 1)[0]);
}


## @fn private $ remain_to_eta($remaining)
# Convert the estimated time to complete the operation in seconds into a
# string representation of the ETA. The string this generates will depend
# on how long the remaining time is - if it is over a day, the string 
# shows the ETA in days and hours. If it is less than a day but more
# than an hour it shows the ETA in hours and minutes. If it is less than
# an hour but more than a minute then the ETA is shown in minutes and 
# seconds, otherwise just the remainaing time in seconds is shown.
#
# @param remaining The estimate of the number of seconds to go before the
#                  progress bar hits 100%.
# @return A string representation of the ETA.
sub remain_to_eta {
    my $remaining = shift;

    # remaining time over a day? Show days and hours
    if($remaining >= 86400) {
        return sprintf " ETA %02dd:%02dh", $remaining / 86400, ($remaining % 86400) / 3600;

    # Time is over an hour? Show hours and minutes
    } elsif($remaining >= 3600) {
        return sprintf " ETA %02dh:%02dm", $remaining / 3600, ($remaining % 3600) / 60;

    # Time is over a minute? Show minutes and seconds
    } elsif($remaining >= 60) {
        return sprintf " ETA %02dm:%02ds", $remaining / 60, $remaining % 60;

    } else {
        return sprintf " ETA %02ds    ", $remaining;
    }
}


## @fn private $ bytes_to_human($bytes)
# Produce a human-readable version of the provided byte count. If $bytes is
# less than 1024 the string returned is in bytes. Between 1024 and 1048576 is 
# in KB, between 1048576 and 1073741824 is in MB, over 1073741824 is in GB
sub bytes_to_human {
    my $bytes = shift;

    if($bytes >= 1073741824) {
        return sprintf("%.2f GB", $bytes / 1073741824);
    } elsif($bytes >= 1048576) {
        return sprintf("%.2f MB", $bytes / 1048576);
    } elsif($bytes >= 1024) {
        return sprintf("%.2f KB", $bytes / 1024);
    } else {
        return "$bytes bytes";
    }
}

1;
