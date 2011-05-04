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
        "line_limit" => 2,
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

    # Set a vaguely sane default for line spacing if needed
    $linespacing = 0.4 if(!defined($linespacing));

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
    $linespacing = 0.4 if(!defined($linespacing));

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
        return "Unable to draw requested string: scaled text too small" if($reqsize < $minsize);

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
    $linespacing = 0.4 if(!defined($linespacing));

    # Start off with the string 'as is'
    my $wstring = $string;
   
    my $sdata;     # somewhere to store size data
    my $lines = 1; # there's currently only one line in the string, we assume...
    do {
        # Split the string into lines if needed
        my @strings = split /\|/, $wstring;

        # Will the string fit into the space needed?
        $sdata = $self -> ttf_string_calcsize($fontname, $colour, \@strings, $minsize, $linespacing)
            or die "Unable to calculate size for $wstring!\n";
    
        # If it won't fit in the width, we need to wrap it (height will be handled for us, but that should
        # never be an issue in normal situations anyway)
        if($sdata -> {"_"} -> {"maxwide"} > $maxwidth) {
            $Text::Wrap::columns   = length($string) / ++$lines;
            $Text::Wrap::separator = "|";
            $wstring = wrap("", "", $string);
        }

    # keep going until the string fits, or we hit the line limit
    } while(($sdata -> {"_"} -> {"maxwide"} > $maxwidth) && ($lines < $self -> {"line_limit"}));

    # Bomb if we hit the split limit
    return "Unable to wrap text into the available space. Line limit exceeded." if($lines >= $self -> {"line_limit"});

    # Okay, get here and wstring contains the wrapped string, so draw it
    return $self -> ttf_string_centred($image, $fontname, $colour, $wstring, $cx, $cy, $reqsize, $minsize, $maxwidth, $maxheight, $linespacing);
}


## @method $ render_text($image, $render, $elemdata)
# Render a text element onto the specified image. This uses the settings in the given
# elemdata hash, in combination with data stored in the render hash, to generate a
# text string on the specified image.
#
# @param image    The image to render the text onto.
# @param render   A reference to the current render hash. This is needed for font and colour lookups.
# @param elemdata A hash ref containing the information about the text to render.
# @return A string containing an error message on error, or undef on success.
sub render_text {
    my $self   = shift;
    my ($image, $render, $elemdata) = @_;

    return $self -> ttf_string_wrap($image, 
                                    $render -> {"image"} -> {"fonts"} -> {"font"} -> {$elemdata -> {"font"}} -> {"content"},
                                    $render -> {"image"} -> {"colours"} -> {"colour"} -> {$elemdata -> {"colour"}} -> {"data"},
                                    $elemdata -> {"content"},
                                    $elemdata -> {"x"}    , $elemdata -> {"y"},
                                    $elemdata -> {"size"} , $elemdata -> {"minsize"},
                                    $elemdata -> {"width"}, $elemdata -> {"height"},
                                    $elemdata -> {"spacing"});
}


## @method $ render_hash($output, $render)
# Generate an image using the rules specified in the provided render control hash. This 
# will use the contents of the supplied render control hash to determine the size and 
# contents of the image written to output. Please see the processor documentation in the
# development wiki for details regarding the contents of the render control hash.
#
# @param output The name of the file to write the generated image to.
# @param render The render control hash containing the directives used to generate the image.
# @return undef on success, otherwise a string containing an error message.
sub render_hash {
    my $self   = shift;
    my $output = shift;
    my $render = shift;

    die "FATAL: Unable to create $output: image width or height can not be 0\n".Data::Dumper -> Dump([$render]) 
        if(!$render -> {"image"} -> {"width"} || !$render -> {"image"} -> {"height"});

    my $image = GD::Image -> new($render -> {"image"} -> {"width"}, $render -> {"image"} -> {"height"}, 1)
        or return "Unable to create new image.";

    # If we have a base image, load and blit it
    if($render -> {"image"} -> {"base"}) {
        # Unless the base appears absolute, we need to prepend the template base directory
        $render -> {"image"} -> {"base"} = path_join($self -> {"template"} -> {"templatedir"}, $render -> {"image"} -> {"base"})
            unless($render -> {"image"} -> {"base"} =~ m|^/|);

        # does the file exist?
        return "Unable to load base image ".$render -> {"image"} -> {"base"}.": file does not exist." unless(-f $render -> {"image"} -> {"base"});

        # Okay, load and get the image size
        my $baseimg = GD::Image -> new($render -> {"image"} -> {"base"})
            or return "Unable to load base image.";
        
        my ($basew, $baseh) = $baseimg -> getBounds();

        die "FATAL: Unable to create $output: base image width or height can not be 0\n" 
            if(!$basew || !$baseh);

        # Copy into the working image
        $image -> copy($baseimg, $render -> {"image"} -> {"basex"} || 0, $render -> {"image"} -> {"basey"} || 0,
                       0, 0, $basew, $baseh);
    }

    # now we need to process the colour hash, allocating colours as necessary.
    foreach my $col (keys(%{$render -> {"image"} -> {"colours"} -> {"colour"}})) {
        # pull the RGB out
        my @vals = $render -> {"image"} -> {"colours"} -> {"colour"} -> {$col} -> {"content"} =~ /([a-fA-F0-9]{2})/g;
        
        return "Malformed colour ($col) specified in image metadata: ".$render -> {"image"} -> {"colours"} -> {"colour"} -> {$col} -> {"content"}
            unless(defined($vals[0]) && defined($vals[1]) && defined($vals[2]));

        # Do the allocate...
        $render -> {"image"} -> {"colours"} -> {"colour"} -> {$col} -> {"data"} = $image -> colorAllocateAlpha(hex($vals[0]),
                                                                                                               hex($vals[1]),
                                                                                                               hex($vals[2]),
                                                                                                               hex($vals[3] || 0));
        # bomb if the result was -1
        return "Unable to allocate colour $col for drawing"
            if($render -> {"image"} -> {"colours"} -> {"colour"} -> {$col} -> {"data"} == -1);
    }

    # Now process each of the elements 
    my $error;
    foreach my $element (keys(%{$render -> {"image"} -> {"elements"} -> {"element"}})) {
        my $elemdata = $render -> {"image"} -> {"elements"} -> {"element"} -> {$element};

        if($elemdata -> {"type"} eq "text") {
            $error = $self -> render_text($image, $render, $elemdata);
        }

        # Did we have any problems? If so, give up now.
        return $error if($error);
    }

    # Save the generated image to the specified file as png
    open(IMG, "> $output")
        or return "Unable to open image output file for writing: $!";
    binmode IMG; # shouldn't be needed on linux, but just in case.
    print IMG $image -> png;
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

    # Parse it into a usable format. This will die on parse errors...
    my $xmldata = XMLin($xmlstr, KeepRoot => 1, ForceArray => ["element", "font", "colour"], ForceContent => 1);

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
# @param output The name of the file to write the generated image to.
# @return undef on success, otherwise an error message.
sub load_render_xml {
    my $self     = shift;
    my $xmlname  = shift;
    my $replhash = shift;
    my $output   = shift;

    my $render = $self -> load_xml($xmlname, $replhash);
    return "Unable to load xml file" if(!$render);
    
    return $self -> render_hash($output, $render);
}


1;
