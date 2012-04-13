## @file
# This file contains the implementation of various image generation tools
# required by the output handlers to generate supporting graphics.
#
# @author  Chris Page &lt;chris@starforge.co.uk&gt;
# @version 1.0
# @date    2 Dec 2010
# @copy    2010, Chris Page &lt;chris@starforge.co.uk&gt;
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
package ImageTools;

use strict;
use GD;
use Text::Wrap; # FIXME: This will break on languages like japanese/chinese!
use Utils qw(path_join);
use XML::Simple;

use Data::Dumper;

# ============================================================================
#  Constructor
#

## @cmethod $ new($args)
# Create a new ImageTools object. This should be called with, at minimum, a reference
# to the template engine. Valid arguments that may be specified in args are:
#
# line_limit  The maximum number of lines that a string may be split into during wrapping.
#             This defaults to 2.
# template    A reference to a template engine object. Must be provided.
#
# @param args A hash of arguments to set.
# @return A new ImageTools object.
sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;

    my $self = {
        "line_limit" => 3,
         @_,
    };

    die "Missing template reference in ImageTools::new()" if(!$self -> {"template"});

    # Tell GD to work in truecolour mode, as we care not about indexed stuff
    GD::Image -> trueColor(1);

    return bless $self, $class;
}


## @method $ ttf_string_calcsize($fontname, $colour, $strings, $reqsize, $linespacing)
# Determine the size of a string or series of strings. This function determines the
# size of each of the strings in the 'strings' array at the request point size. This
# stores the width and height of each string, the maximum width and height, and the
# sum of the heights.
#
# @param fontname    The path to the truetype font to use.
# @param colour      The colour to draw the string in,
# @param strings     A reference to an array of strings to calculate sizes for.
# @param reqsize     The preferred size to draw the string at in points.
# @param linespacing Optional argument passed to stringFT to control spacing in multiline strings.
# @return A reference to a hash containing the string size information.
sub ttf_string_calcsize {
    my $self = shift;
    my ($fontname, $colour, $strings, $reqsize, $linespacing) = @_;

    die "Incorrect argument to ttf_string_calcsize - strings must be arrayref"
        unless(ref($strings) eq "ARRAY");

    # Set a vaguely sane default for line spacing if needed
    $linespacing = 0.5 if(!defined($linespacing));

    # We need to store stats in here, as well as the string dimensions,
    # so use "_" as the name for the maximums storage hash
    my $sdata = { "_" => { "maxwide" => 0,
                           "maxhigh" => 0,
                           "sumhigh" => 0,
                         }
                };

    my $scount = scalar(@$strings);
    for(my $pos = 0; $pos < $scount; ++$pos) {
        # work out how big the string is at the requested size. Doing the bounds test at 100,100 helps avoid fun with negatives...
        my @bounds = GD::Image -> stringFT($colour, $fontname, $reqsize, 0, 100, 100, $strings -> [$pos], {"linespacing" => $linespacing, "resolution" => "200,200" });

        # We can't do anything if we can't get bounds
        return $self -> {"template"} -> replace_langvar("CERT_ERR_NOBOUND", "", {"***error***" => $@}) if(!@bounds);

        # Store the width and height
        $sdata -> {$pos} -> {"width"}  = $bounds[2] - $bounds[0];
        $sdata -> {$pos} -> {"height"} = $bounds[3] - $bounds[5];

        # We'll also need offsets to draw the text where we actually expect it to be
        $sdata -> {$pos} -> {"xoff"} = 100 - $bounds[0];
        $sdata -> {$pos} -> {"yoff"} = 100 - $bounds[7];

        # Are we looking at the maximum sizes?
        $sdata -> {"_"} -> {"maxwide"} = $sdata -> {$pos} -> {"width"}  if($sdata -> {$pos} -> {"width"}  > $sdata -> {"_"} -> {"maxwide"});
        $sdata -> {"_"} -> {"maxhigh"} = $sdata -> {$pos} -> {"height"} if($sdata -> {$pos} -> {"height"} > $sdata -> {"_"} -> {"maxhigh"});

        # And add the height onto the running total
        $sdata -> {"_"} -> {"sumhigh"} += $sdata -> {$pos} -> {"height"} * ($linespacing * 2);

        # Now try to work out the theoretical Y position relative to an imginary origin
        if($pos > 0) {
            $sdata -> {$pos} -> {"ypos"} = $sdata -> {$pos - 1} -> {"ypos"} + ($sdata -> {$pos - 1} -> {"height"} * ($linespacing * 2));
        } else {
            $sdata -> {$pos} -> {"ypos"} = 0;
        }
    }

    return $sdata;
}


## @method $ ttf_string_centred($image, $fontname, $colour, $string, $cx, $cy, $reqsize, $minsize, $maxwidth)
# Draw a horizontally and vertically centred string at the specified coordinates. This will
# write a string to the image in the specified font and colour, centred around the x and y.
# If the font width at the requested size is less than or equal to the maximum width then the
# font is drawn at the requested point size, otherwise the size is scaled down to fit the string
# inside the maximum width. If the scaling required results in a point size less than the
# provided minimum size, this will return an error.
#
# @param image       The image to draw the string into.
# @param fontname    The path to the truetype font to use.
# @param colour      The colour to draw the string in,
# @param string      The text to draw into the image.
# @param cx          The x coordinate the text should be centred around.
# @param cy          The y coordinate the text should be centred around.
# @param reqsize     The preferred size to draw the string at in points.
# @param minsize     The minimum point size that can be tolerated before an error.
# @param maxwidth    The width the string must fit entirely within.
# @param maxheight   The height the string must fit entirely within.
# @param linespacing Optional argument passed to stringFT to control spacing in multiline strings.
# @return A string containing an error message on error, or undef on success
sub ttf_string_centred {
    my $self = shift;
    my ($image, $fontname, $colour, $string, $cx, $cy, $reqsize, $minsize, $maxwidth, $maxheight, $linespacing) = @_;

    # Set a vaguely sane default for line spacing if needed
    $linespacing = 0.5 if(!defined($linespacing));

    # Now, the string we've been given might contain | which indicates that the line should be split
    # so, convert the string into an array of substrings...
    my @strings = split /\|/, $string;

    # Now we need to work out the bounds of each string in turn so that we can calculate overall size
    # and, from that, scales
    my $sdata = $self -> ttf_string_calcsize($fontname, $colour, \@strings, $reqsize, $linespacing);

    # If the result from calcsize is not a reference, it's an error string...
    return $sdata if(!ref($sdata));

    # Is the maximum width over the limit?
    if($sdata -> {"_"} -> {"maxwide"} > $maxwidth || $sdata -> {"_"} -> {"sumhigh"} > $maxheight) {
        # Calcualte how much we're overflowing width and height
        my $wspill = $sdata -> {"_"} -> {"maxwide"} - $maxwidth;
        my $hspill = $sdata -> {"_"} -> {"sumhigh"} - $maxheight;

        # Now scale to fit the strings inside the space we have
        # Has the string spilled over the width, and is the width spill worse than any
        # height spill? If so, change the scale to fit the width in (which should fit the height)
        if($wspill > 0 && $wspill >= $hspill) {
            $reqsize *= ($maxwidth / $sdata -> {"_"} -> {"maxwide"});

        # Has the string spilled over the height, and is the height spill worse than any
        # width spill? If so, scale down to fit the string into the available height.
        } elsif($hspill > 0 && $hspill > $wspill) {
            $reqsize *= ($maxheight / $sdata -> {"_"} -> {"sumhigh"});
        } else {
            die "FATAL: ttf_string_centred unable to scale string properly. This should not happen.\n";
        }

        # Is the new size within limits? If not, exit with an error
        return sprintf("Unable to draw requested string, scaled text too small (would require %.1f minimum is %.1f)", $reqsize, $minsize) if($reqsize < $minsize);

        # scaled point size is acceptable, recalculate the bounding boxes
        $sdata = $self -> ttf_string_calcsize($fontname, $colour, \@strings, $reqsize, $linespacing);
    }

    # Draw the strings...
    my $scount = scalar(@strings);
    for(my $pos = 0; $pos < $scount; ++$pos) {
        # Get here and the string is within limits at some acceptable size, so draw it
        $image -> stringFT($colour, $fontname, $reqsize, 0,
                           $cx - ($sdata -> {$pos} -> {"width"} / 2)  + $sdata -> {$pos} -> {"xoff"},
                           $cy - ($sdata -> {"_"} -> {"sumhigh"} / 2) + $sdata -> {$pos} -> {"ypos"} + $sdata -> {$pos} -> {"yoff"},
                           $strings[$pos],
                           {"linespacing" => $linespacing, "resolution" => "200,200" });
    }

    return undef;
}


## @method $ ttf_string_wrap($image, $fontname, $colour, $string, $cx, $cy, $reqsize, $minsize, $maxwidth, $maxheight, $linespacing)
# Given a string, attempt to draw it centred around the specified point, taking up no more than the
# specified maximum width and height, wrapping the string as necessary. This performs much the same
# job as ttf_string_centred(), except that it will attempt to wrap the specified string if it is
# too long to fit within the specified width before resorting to scaling.
#
# @param image       The image to draw the string into.
# @param fontname    The path to the truetype font to use.
# @param colour      The colour to draw the string in,
# @param string      The text to draw into the image.
# @param cx          The x coordinate the text should be centred around.
# @param cy          The y coordinate the text should be centred around.
# @param reqsize     The preferred size to draw the string at in points.
# @param minsize     The minimum point size that can be tolerated before an error.
# @param maxwidth    The width the string must fit entirely within.
# @param maxheight   The height the string must fit entirely within.
# @param linespacing Optional argument passed to stringFT to control spacing in multiline strings.
# @return A string containing an error message on error, or undef on success
sub ttf_string_wrap {
    my $self = shift;
    my ($image, $fontname, $colour, $string, $cx, $cy, $reqsize, $minsize, $maxwidth, $maxheight, $linespacing) = @_;

    # Set a vaguely sane default for line spacing if needed
    $linespacing = 0.5 if(!defined($linespacing));

    # Work out the wrapped, fitted string.
    my ($wstring, $sdata, $fontsize) = $self -> get_fixedlabel_size($fontname, $string, $reqsize, $minsize, $maxwidth, $maxheight, $linespacing);
    return $wstring unless($fontsize);

    # Okay, get here and wstring contains the wrapped string, so draw it
    return $self -> ttf_string_centred($image, $fontname, $colour, $wstring, $cx, $cy, $fontsize, $minsize, $maxwidth, $maxheight, $linespacing);
}


## @method $ render_text($image, $colref, $fontref, $elemdata)
# Render a text element onto the specified image. This uses the settings in the given
# elemdata hash, in combination with data stored in the render hash, to generate a
# text string on the specified image.
#
# @param image    The image to render the text onto.
# @param colref   A reference to a hash of colours available for rendering.
# @param fontref  A reference to a hash of fonts available for rendering.
# @param elemdata A hash ref containing the information about the text to render.
# @return A string containing an error message on error, or undef on success.
sub render_text {
    my $self   = shift;
    my ($image, $colref, $fontref, $elemdata) = @_;

    # Strip any leading or trailing whitespace
    $elemdata -> {"content"} =~ s/^\s*(.*?)\s*$/$1/;

    return $self -> ttf_string_wrap($image,
                                    $fontref  -> {"font"} -> {$elemdata -> {"font"}} -> {"content"},
                                    $colref   -> {"colour"} -> {$elemdata -> {"colour"}} -> {"data"},
                                    $elemdata -> {"content"},
                                    $elemdata -> {"x"}    , $elemdata -> {"y"},
                                    $elemdata -> {"size"} , $elemdata -> {"minsize"},
                                    $elemdata -> {"width"}, $elemdata -> {"height"},
                                    $elemdata -> {"spacing"});
}


## @method $ allocate_colours($image, $colref)
# Allocate the colours used by a render hash. This will go through the entries inside
# the provided colours hash, allocating colours in the provided image for each.
#
# @param image  The image to allocate colours in.
# @param colref A reference to a hash of colours.
# @return undef on success, an error message otherwise.
sub allocate_colours {
    my $self   = shift;
    my $image  = shift;
    my $colref = shift;

    # now we need to process the colour hash, allocating colours as necessary.
    foreach my $col (keys(%{$colref -> {"colour"}})) {
        # pull the RGB out
        my @vals = $colref -> {"colour"} -> {$col} -> {"content"} =~ /([a-fA-F0-9]{2})/g;

        return "Malformed colour ($col) specified in image metadata: ".$colref -> {"colour"} -> {$col} -> {"content"}
            unless(defined($vals[0]) && defined($vals[1]) && defined($vals[2]));

        # Do the allocate...
        $colref -> {"colour"} -> {$col} -> {"data"} = $image -> colorAllocateAlpha(hex($vals[0]),
                                                                                   hex($vals[1]),
                                                                                   hex($vals[2]),
                                                                                   hex($vals[3] || 0));
        # bomb if the result was -1
        return "Unable to allocate colour $col for drawing"
            if($colref -> {"colour"} -> {$col} -> {"data"} == -1);
    }

    # All processed fine, return undef.
    return undef;
}


## @method void copy_fragment($back, $frag, $image)
# Copy a fragment of the back image to the working image. This will copy a piece
# of the back image to the working image using the contents of the specified
# fragment to determine the source location and size, the destination location,
# and whether the fragment copy is repeated in the x, y, or both.
#
# @param back  The back image, the source of the fragment to copy.
# @param frag  A hash describing the fragment to copy.
# @param image The image to copy the fragment into.
sub copy_fragment {
    my $self  = shift;
    my $back  = shift;
    my $frag  = shift;
    my $image = shift;

    # Work out start values...
    my ($dsx, $dsy) = ($frag -> {"dx"}, $frag -> {"dy"});

    # fix up any 'max'es in there
    $dsx = $image -> width  - $frag -> {"width"}  if($dsx eq "max");
    $dsy = $image -> height - $frag -> {"height"} if($dsy eq "max");

    # If the destination values are negative, they are relative to the bottom/right
    $dsx = $image -> width + $dsx  if($dsx < 0);
    $dsy = $image -> height + $dsy if($dsy < 0);

    # Now work out end values
    my ($dex, $dey) = ($frag -> {"ex"}, $frag -> {"ey"});

    # If the ex/ey values were negative, they're relative to the bottom/right of
    # the image, so convert them
    $dex = $image -> width + $dex  if(defined($dex) && $dex < 0);
    $dey = $image -> height + $dey if(defined($dey) && $dey < 0);

    # Now work out end points if we don't have them manually specified.
    if($frag -> {"repeat"} eq "x" && !defined($dex)) {
        $dex = $image -> width  - $frag -> {"width"};
    } elsif($frag -> {"repeat"} eq "y" && !defined($dey)) {
        $dey = $image -> height - $frag -> {"height"};
    } elsif($frag -> {"repeat"} eq "both") {
        $dex = $image -> width  - $frag -> {"width"}  unless(defined($dex));
        $dey = $image -> height - $frag -> {"height"} unless(defined($dey));
    } else {
        $dex = $dsx unless(defined($dex));
        $dey = $dsy unless(defined($dey));
    }

    # Do the copy, for non-repeating images, the whiles will only
    # execute the once...
    my ($xpos, $ypos) = ($dsx, $dsy);
    while($ypos <= $dey) {
        while($xpos <= $dex) {
            $image -> copy($back, $xpos, $ypos, $frag -> {"sx"}, $frag -> {"sy"}, $frag -> {"width"}, $frag -> {"height"});

            $xpos += $frag -> {"width"};
        }
        $ypos += $frag -> {"height"};
        $xpos = $dsx;
    }
}


## @method @ get_fixedlabel_size($fontname, $string, $fontsize, $minsize, $maxwidth, $maxheight, $linespacing)
# Determine the optimal size to draw the specified string so that it will fit within the
# width and height.
#
# @param fontname    The path to the truetype font to use.
# @param string      The text to draw into the image.
# @param fontsize    The preferred size to draw the string at in points.
# @param minsize     The minimum point size that can be tolerated before an error.
# @param maxwidth    The width the string must fit entirely within.
# @param maxheight   The height the string must fit entirely within.
# @param linespacing Optional argument passed to stringFT to control spacing in multiline strings.
# @return An array of three values: the string wrapped so it will fit, the size data hash, and the font
#         size to draw the string in. If the string will not fit, this returns undefs.
sub get_fixedlabel_size {
    my $self = shift;
    my ($fontname, $string, $fontsize, $minsize, $maxwidth, $maxheight, $linespacing) = @_;
    my ($sdata, $lines, $workstring);

    # Long words shouldn't be broken
    $Text::Wrap::huge = "overflow";
    $Text::Wrap::separator = "|";

    do { # while($fontsize >= $minsize});
        $lines = 1;            # there's currently only one line in the string
        $workstring = $string; # make a working copy of the string so we can wrap it as needed

        do { # while($sdata -> {"_"} -> {"maxwide"} > $maxwidth && $sdata -> {"_"} -> {"sumhigh"} < $maxheight);

            # Split the string into lines if needed
            my @strings = split /\|/, $workstring;

            # Will the string fit into the space needed?
            $sdata = $self -> ttf_string_calcsize($fontname,
                                                  0, # colour should be irrelivant here...
                                                  \@strings,
                                                  $fontsize,
                                                  $linespacing)
                or die "Unable to calculate size for $workstring!\n";

            # If the string fits into the preferred size, we're good to go
            if($sdata -> {"_"} -> {"maxwide"} <= $maxwidth && $sdata -> {"_"} -> {"sumhigh"} < $maxheight) {
                # Return the string that worked, and the dimensions
                return ($workstring, $sdata, $fontsize);

            # If the string didn't fit into the width, but it did fit the height, wrap it
            } elsif($sdata -> {"_"} -> {"maxwide"} > $maxwidth && $sdata -> {"_"} -> {"sumhigh"} < $maxheight) {
                $Text::Wrap::columns = int(length($workstring) / ++$lines);
                $workstring = eval { wrap("", "", $string) };

                die "FATAL: Generating fixed button string failed: $@" if($@);
            }

        # keep going until the string fits the width, or we overflow the height
        } while($sdata -> {"_"} -> {"maxwide"} > $maxwidth && $sdata -> {"_"} -> {"sumhigh"} < $maxheight && $lines <= $self -> {"line_limit"});

        # reduce the font size a notch
        --$fontsize;

    # Keep trying until we either need a smaller font than we're allowed or run out of lines
    } while($fontsize >= $minsize);

    # Bomb if we have hit the split limit
    return ("Unable to wrap text into the available space. Line limit exceeded.", undef, undef)
        if($lines > $self -> {"line_limit"});

    # Get here and it won't fit
    return ("Unable to fit text into the available space. Font size too small (aborted at $fontsize)", undef, undef);
}


## @method @ get_elasticlabel_size($render, $label)
# Attempt to calculate the optimal size and font size for the specified lable string. This will
# try to fit the label into the preferred size, wrapping the string, reducing to font, and
# increasing the preferred size if needed. If the required size exceeds twice the preferred
# size without fitting the label in, even at the smallest font size, this will give up and
# return undefs.
#
# @param render A reference to the render hash.
# @param label  The label string to calculate the size for.
# @return An array of 5 elements: the potentially wrapped label string, the size of the rendered string,
#         the font size the string was rendered at, and the width and height the string fitted into.
#         If the string does not fit into twice the preferred size at the smallest font size, all these
#         will be undef.
sub get_elasticlabel_size {
    my $self   = shift;
    my $render = shift;
    my $label  = shift;

    # Long words shouldn't be broken
    $Text::Wrap::huge = "overflow";
    $Text::Wrap::separator = "|";

    # Linespacing is needed if we wrap...
    my $linespacing = defined($render -> {"elasticbutton"} -> {"label"} -> {"linespacing"}) ?
                          $render -> {"elasticbutton"} -> {"label"} -> {"linespacing"} :
                          0.5;

    # replace | with spaces in the label contents before we do anything else, so we have a single line,
    # compress repeated spaces to a single space, and remove leading and trailing whitespace.
    $label =~ s/\|/ /g;
    $label =~ s/\s+/ /g;
    $label =~ s/^\s*(.*?)\s*$/$1/;

    my $sdata; # somewhere to store size data while we work

    # Okay, start with the preferred size, minus padding...
    my ($pwidth, $pheight) = ($render -> {"elasticbutton"} -> {"prefwidth"}  - $render -> {"elasticbutton"} -> {"padding"},
                              $render -> {"elasticbutton"} -> {"prefheight"} - $render -> {"elasticbutton"} -> {"padding"});
    do { # while($pwidth  <= ($render -> {"elasticbutton"} -> {"prefwidth"} * 2) && ...);

        # Use the requested font size, we may need to come down from this later
        my $fontsize = $render -> {"elasticbutton"} -> {"label"} -> {"size"};
        do { # while($fontsize >= $render -> {"elasticbutton"} -> {"label"} -> {"minsize"});

            my $lines = 1;           # there's currently only one line in the string, see above
            my $workstring = $label; # make a working copy of the string so we can wrap it as needed
            do { # while($sdata -> {"_"} -> {"maxwide"} > $pwidth && $sdata -> {"_"} -> {"sumhigh"} < $pheight);

                # Split the string into lines if needed
                my @strings = split /\|/, $workstring;

                # Will the string fit into the space needed?
                $sdata = $self -> ttf_string_calcsize($render -> {"elasticbutton"} -> {"fonts"} -> {"font"} -> {$render -> {"elasticbutton"} -> {"label"} -> {"font"}} -> {"content"},
                                                      0, # colour should be irrelivant here...
                                                      \@strings,
                                                      $fontsize,
                                                      $linespacing)
                    or die "Unable to calculate size for $workstring!\n";

                # If the string fits into the preferred size, we're good to go
                if($sdata -> {"_"} -> {"maxwide"} <= $pwidth &&$sdata -> {"_"} -> {"sumhigh"} <= $pheight) {
                    # Return the string that worked, and the dimensions
                    return ($workstring, $sdata, $fontsize, $pwidth, $pheight);

                # If the string didn't fit into the width, but it did fit the height, wrap it
                } elsif($sdata -> {"_"} -> {"maxwide"} > $pwidth && $sdata -> {"_"} -> {"sumhigh"} <= $pheight) {
                    $Text::Wrap::columns   = int(length($workstring) / ++$lines);
                    $workstring = eval { wrap("", "", $label) };

                    die "Generating elastic button string failed: $@" if($@);
                }

            # keep going until the string fits the width, or we overflow the height
            } while($sdata -> {"_"} -> {"maxwide"} > $pwidth && $sdata -> {"_"} -> {"sumhigh"} <= $pheight);

            # reduce the font size a notch
            --$fontsize;

        # Keep trying until we either need a smaller font than we're allowed
        } while($fontsize >= $render -> {"elasticbutton"} -> {"label"} -> {"minsize"});

        # Text can't fit inside the preferred size even at the smallest font, so
        # increase the preferred size by 10% of the base preferred size
        $pwidth  += int($render -> {"elasticbutton"} -> {"prefwidth"} * 0.1);
        $pheight += int($render -> {"elasticbutton"} -> {"prefheight"} * 0.1);

    # Keep trying until we go over double the preferred width or height
    } while($pwidth  <= ($render -> {"elasticbutton"} -> {"prefwidth"} * 2) &&
            $pheight <= ($render -> {"elasticbutton"} -> {"prefheight"} * 2));

    # Get here and the text can't fit in twice the preferred size, even at the smallest font
    return (undef, undef, undef, undef, undef);
}


## @method $ render_basicimage($render)
# Render a basic image using the rules specified in the provided render control hash.
# This will create an image with a fixed width and height, and a single background
# graphic. It can be used to generate course map buttons and other regular, simple
# graphics that do not require resizing of the image to its contents.
#
# A sample xml description that will result in a button when converted to a hash and
# passed to this function:
#
# <basicimage base="theme_button_off.png" basex="0" basey="0" width="256" height="64">
#    <colours>
#        <colour name="white">#FFFFFF</colour>
#    </colours>
#    <fonts>
#        <font name="arialbd">/usr/share/fonts/corefonts/arialbd.ttf</font>
#    </fonts>
#    <elements>
#        <element type="text" name="title" font="arialbd" colour="white" x="128" y="32" width="240" height="50" size="20" minsize="11">
#        Button Text
#        </element>
#    </elements>
#</basicimage>
#
# @param render A reference to a render control hash containing the directives used to generate the image.
# @return A reference to an image on success, otherwise an error message.
sub render_basicimage {
    my $self   = shift;
    my $render = shift;

    die "FATAL: Unable to create image: image width or height can not be 0\n".Data::Dumper -> Dump([$render])
        if(!$render -> {"basicimage"} -> {"width"} || !$render -> {"basicimage"} -> {"height"});

    my $image = GD::Image -> new($render -> {"basicimage"} -> {"width"}, $render -> {"basicimage"} -> {"height"}, 1)
        or return "Unable to create new image.";

    # If we have a base image, load and blit it
    if($render -> {"basicimage"} -> {"base"}) {
        # Unless the base appears absolute, we need to prepend the template base directory
        $render -> {"basicimage"} -> {"base"} = path_join($self -> {"template"} -> {"basedir"}, $self -> {"template"} -> {"theme"}, $render -> {"basicimage"} -> {"base"})
            unless($render -> {"basicimage"} -> {"base"} =~ m|^/|);

        # does the file exist?
        return "Unable to load base image ".$render -> {"basicimage"} -> {"base"}.": file does not exist." unless(-f $render -> {"basicimage"} -> {"base"});

        # Okay, load and get the image size
        my $baseimg = GD::Image -> new($render -> {"basicimage"} -> {"base"})
            or return "Unable to load base image.";

        my ($basew, $baseh) = $baseimg -> getBounds();

        die "FATAL: Unable to create image: base image width or height can not be 0\n"
            if(!$basew || !$baseh);

        # Copy into the working image
        $image -> copy($baseimg, $render -> {"basicimage"} -> {"basex"} || 0, $render -> {"basicimage"} -> {"basey"} || 0,
                       0, 0, $basew, $baseh);
    }

    my $result = $self -> allocate_colours($image, $render -> {"basicimage"} -> {"colours"});
    return $result if($result);

    # Now process each of the elements
    my $error;
    foreach my $element (keys(%{$render -> {"basicimage"} -> {"elements"} -> {"element"}})) {
        my $elemdata = $render -> {"basicimage"} -> {"elements"} -> {"element"} -> {$element};

        if($elemdata -> {"type"} eq "text") {
            $error = $self -> render_text($image,
                                          $render -> {"basicimage"} -> {"colours"},
                                          $render -> {"basicimage"} -> {"fonts"},
                                          $elemdata);
        }

        # Did we have any problems? If so, give up now.
        return $error if($error);
    }

    return $image;
}


## @method $ render_elasicbutton($render)
# Render a button that attempts to size itself to fit its contents. This is considerably
# more complicated than render_basicimage(), as it needs to preform multiple iterative steps
# to determine how large the image should be. Note that this only supports a single text
# string as the button contents.
#
# A sample xml description that will result in a button when converted to a hash and
# passed to this function:
#
# <elasticbutton prefwidth="256" prefheight="64" padding="10"> <!-- prefwidth/height are the preferred width and height -->
#    <colours>
#        <colour name="white">#FFFFFF</colour>
#    </colours>
#    <fonts>
#        <font name="arialbd">/usr/share/fonts/corefonts/arialbd.ttf</font>
#    </fonts>
#    <backimg name="green_button_base.png" width="256" height="64">
#        <fragment name="back" sx="5"   sy="5" width="5" height="5" repeat="x,y" priority="1" />
#        <fragment name="tl"   sx="0"   sy="0" dx="0" dy="0" width="5" height="5" repeat="none" priority="3" />
#        <fragment name="t"    sx="5"   sy="0" dy="0" width="5" height="5" repeat="x"    priority="2" />
#        <fragment name="tr"   sx="250" sy="0" dx="max" dy="0" width="5" height="5" repeat="none" priority="3" />
#        ... etc...
#    </backimg>
#    <label name="label" font="arialbd" colour="white" minsize="11" size="20">
#        Label text here
#    </label>
# </elasticbutton>
#
# @param render A reference to a render control hash containing the directives used to generate the image.
# @return A reference to an image on success, otherwise an error message.
sub render_elasicbutton {
    my $self   = shift;
    my $render = shift;

    # Work out the 'optimal' label size, and the size of the image needed to show it.
    my ($label, $shash, $fontsize, $width, $height) = $self -> get_elasticlabel_size($render, $render -> {"elasticbutton"} -> {"label"} -> {"content"});

    # Did we successfully get a size? If not, bomb.
    return "Unable to generate button size for requested string" if(!defined($label));

    # Make sure that the padding is included
    my ($xremain, $yremain) = ($width  - $shash -> {"_"} -> {"maxwide"}, $height - $shash -> {"_"} -> {"sumhigh"});
    $width  += ($render -> {"elasticbutton"} -> {"padding"} - $xremain) if($xremain < $render -> {"elasticbutton"} -> {"padding"});
    $height += ($render -> {"elasticbutton"} -> {"padding"} - $yremain) if($yremain < $render -> {"elasticbutton"} -> {"padding"});

    # Now we can start making the image...
    my $image = GD::Image -> new($width, $height, 1)
        or return "Unable to create new image.";

    $image -> alphaBlending(0); # turn off blending, as we need to preserve alpha.

    # If we have a backimg, process it
    if($render -> {"elasticbutton"} -> {"backimg"}) {
        $render -> {"elasticbutton"} -> {"backimg"} -> {"name"} = path_join($self -> {"template"} -> {"basedir"}, $self -> {"template"} -> {"theme"}, $render -> {"elasticbutton"} -> {"backimg"} -> {"name"})
            unless($render -> {"elasticbutton"} -> {"backimg"} -> {"name"} =~ m|^/|);

        my $backimg = GD::Image -> new($render -> {"elasticbutton"} -> {"backimg"} -> {"name"})
            or return "Unable to load background image for elastic button: $!";

        # We have the image, double-check that the dimensions match
        return "Background image size mismatch. Abordting for safety"
            if($backimg -> width != $render -> {"elasticbutton"} -> {"backimg"} -> {"width"} || $backimg -> height != $render -> {"elasticbutton"} -> {"backimg"} -> {"height"});

        # Dimensions match, process the fragments.
        my @frags = sort  { die "Attempt to sort fragment without priority while comparing $a and $b"
                               if(!$render -> {"elasticbutton"} -> {"backimg"} -> {"fragment"} -> {$a} -> {"priority"} ||
                                  !$render -> {"elasticbutton"} -> {"backimg"} -> {"fragment"} -> {$a} -> {"priority"});

                           return ($render -> {"elasticbutton"} -> {"backimg"} -> {"fragment"} -> {$a} -> {"priority"}
                                   <=>
                                   $render -> {"elasticbutton"} -> {"backimg"} -> {"fragment"} -> {$b} -> {"priority"});
                         }
                         keys(%{$render -> {"elasticbutton"} -> {"backimg"} -> {"fragment"}});
        foreach my $frag (@frags) {
            my $fragdata = $render -> {"elasticbutton"} -> {"backimg"} -> {"fragment"} -> {$frag};
            $self -> copy_fragment($backimg, $fragdata, $image);
        }
    }

    # Get the colours we need...
    my $result = $self -> allocate_colours($image, $render -> {"elasticbutton"} -> {"colours"});
    return $result if($result);

    $image -> alphaBlending(1); # need alpha back on, or font rendering looks like ass.

    # Now do label rendering
    $self -> ttf_string_centred($image,
                                $render -> {"elasticbutton"} -> {"fonts"} -> {"font"} -> {$render -> {"elasticbutton"} -> {"label"} -> {"font"}} -> {"content"},
                                $render -> {"elasticbutton"} -> {"colours"} -> {"colour"} -> {$render -> {"elasticbutton"} -> {"label"} -> {"colour"}} -> {"data"},
                                $label,
                                $width / 2, $height / 2,
                                $fontsize,
                                $render -> {"elasticbutton"} -> {"label"} -> {"minsize"},
                                $width, $height,
                                $render -> {"elasticbutton"} -> {"label"} -> {"linespacing"});
    # Should be it all
    return $image;
}


## @method $ render_hash($render, $output)
# Generate an image using the rules specified in the provided render control hash. This
# will use the contents of the supplied render control hash to determine the size and
# contents of the image written to output. Please see the processor documentation in the
# development wiki for details regarding the contents of the render control hash.
#
# @param render The render control hash containing the directives used to generate the image.
# @param output The name of the file to write the generated image to. If this is undef,
#               the image is returned rather than saved.
# @return undef (or a reference to an image if output is undef) on success, otherwise
#         a string containing an error message.
sub render_hash {
    my $self   = shift;
    my $render = shift;
    my $output = shift;
    my $image;

    # We only have one root key in the render hash (if we have more, it gets ignored anyway)
    # so find out what it calls itself so we can work out how to process it
    my $type = (keys(%$render))[0];

    if($type eq "basicimage") {
        $image = $self -> render_basicimage($render);
    } elsif($type eq "elasticbutton") {
        $image = $self -> render_elasicbutton($render);
    } else {
        return "Unsupported render type in hash.";
    }

    # If the image is not a hash ref, it must be an error message... unless we have
    # no output string, in which case it needs to be returned anyway
    return $image if(ref($image) ne "GD::Image" || !defined($output));

    # Save the generated image to the specified file as png
    open(IMG, "> $output")
        or return "Unable to open image output file for writing: $!";
    binmode IMG; # shouldn't be needed on linux, but just in case.
    $image -> saveAlpha(1);
    print IMG $image -> png; # make sure alpha is saved
    close(IMG);

    return undef;
}


## @method $ load_xml($xmlname, $replhash)
# Load the specified xml file from the template tree, replacing any markers it contains
# with the contents of the specified hash, and then convert it to a hash. This uses the
# template module load_template() function to load the xml into memory, the replhash
# should contain a reference to a hash of markers and replacements in the same fashion
# as load_template()'s second argument.
#
# @param xmlname  The name of the xml file to load from the template hierarchy.
# @param replhash A reference to a hash of key-value pairs that will be used to replace
#                 markers in the xml.
# @return A reference to the parsed XML hash.
sub load_xml {
    my $self     = shift;
    my $xmlname  = shift;
    my $replhash = shift;

    # load the xml as if it was a normal template
    my $xmlstr = $self -> {"template"} -> load_template($xmlname, $replhash);

    die "XML template load failed: $xmlstr\n" if($xmlstr !~ /^<\?xml/);

    # Parse it into a usable format. This will die on parse errors...
    my $xmldata = XMLin($xmlstr, KeepRoot => 1, ForceArray => ["fragment", "element", "font", "colour"], ForceContent => 1);

    return $xmldata;
}


## @method $ load_render_xml($xmlname, $replhash, $output)
# A convenience function that will load and render the specified render spec xml
# file to the provided outname as png. This essentially does the same thing as
# calling load_xml() followed by render_hash() on the former's result.
#
# @param xmlname  The name of the xml file to load from the template hierarchy.
# @param replhash A reference to a hash of key-value pairs that will be used to replace
#                 markers in the xml.
# @param output The name of the file to write the generated image to. If undef, the
#               image is returned rather than undef.
# @return undef (or a reference to an image, if output is undef) on success,
#         otherwise an error message.
sub load_render_xml {
    my $self     = shift;
    my $xmlname  = shift;
    my $replhash = shift;
    my $output   = shift;

    my $render = $self -> load_xml($xmlname, $replhash);
    return "Unable to load xml file" if(!$render);

    return $self -> render_hash($render, $output);
}


1;
