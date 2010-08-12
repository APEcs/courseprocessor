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
our @EXPORT_OK = qw(path_join check_directory hashmerge text_to_html fix_entities fix_all_entities load_complex_template load_complex_template_escape load_template load_file write_complex_template string_to_seconds build_select limit_length resolve_path reset_pointprogress update_pointprogress lead_zero);
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


# ============================================================================
#  HTML manipulation
#   
my %tags    = ( "b" => "bold",
                "i" => "italic",
                "u" => "uline");
my %smilies = ( ":D"      => "<img src=\"smilies/happy.gif\" alt=\"Happy\" width=\"15\" height=\"15\" />",
                ":-D"     => "<img src=\"smilies/happy.gif\" alt=\"Happy\" width=\"15\" height=\"15\" />",
                ":)"      => "<img src=\"smilies/smile.gif\" alt=\"Smile\" width=\"15\" height=\"15\" />",
                ":-)"     => "<img src=\"smilies/smile.gif\" alt=\"Smile\" width=\"15\" height=\"15\" />",
                ":("      => "<img src=\"smilies/sad.gif\" alt=\"Sad\" width=\"15\" height=\"15\" />",
                ":-("     => "<img src=\"smilies/sad.gif\" alt=\"Sad\" width=\"15\" height=\"15\" />",
                ":o"      => "<img src=\"smilies/surprised.gif\" alt=\"Surprised\" width=\"15\" height=\"15\" />",
                ":shock:" => "<img src=\"smilies/eek.gif\" alt=\"Shocked\" width=\"15\" height=\"15\" />",
                ":|"      => "<img src=\"smilies/frown.gif\" alt=\"Frown\" width=\"15\" height=\"15\" />",
                ":/"      => "<img src=\"smilies/frown.gif\" alt=\"Frown\" width=\"15\" height=\"15\" />",
                ":-|"     => "<img src=\"smilies/frown.gif\" alt=\"Frown\" width=\"15\" height=\"15\" />",
                "8)"      => "<img src=\"smilies/cool.gif\" alt=\"Cool\" width=\"15\" height=\"15\" />",
                "8-)"     => "<img src=\"smilies/cool.gif\" alt=\"Cool\" width=\"15\" height=\"15\" />",
                ":lol:"   => "<img src=\"smilies/lol.gif\" alt=\"Laughing\" width=\"15\" height=\"15\" />",
                ":x"      => "<img src=\"smilies/mad.gif\" alt=\"Mad\" width=\"15\" height=\"15\" />",
                "x("      => "<img src=\"smilies/mad.gif\" alt=\"Mad\" width=\"15\" height=\"15\" />",
                ":P"      => "<img src=\"smilies/tongue.gif\" alt=\"Ppppptht\" width=\"15\" height=\"15\" />",
                ":p"      => "<img src=\"smilies/tongue.gif\" alt=\"Ppppptht\" width=\"15\" height=\"15\" />",
                ":-p"     => "<img src=\"smilies/tongue.gif\" alt=\"Ppppptht\" width=\"15\" height=\"15\" />",
                ":oopd:"  => "<img src=\"smilies/emb.gif\" alt=\"Embarassed\" width=\"15\" height=\"15\" />",
                ":weird:" => "<img src=\"smilies/weird.gif\" alt=\"Weird\" width=\"15\" height=\"15\" />",
                ":evil:"  => "<img src=\"smilies/ebil.gif\" alt=\"Evil\" width=\"15\" height=\"15\" />",
                ":wot:"   => "<img src=\"smilies/wot.gif\" alt=\"Wot\" width=\"15\" height=\"15\" />",
                ":roll:"  => "<img src=\"smilies/wolleyes.gif\" alt=\"Roll\" width=\"15\" height=\"15\" />",
                ":wink:"  => "<img src=\"smilies/wink.gif\" alt=\"Wink\" width=\"15\" height=\"15\" />",
                ";)"      => "<img src=\"smilies/wink.gif\" alt=\"Wink\" width=\"15\" height=\"15\" />",
                ";-)"     => "<img src=\"smilies/wink.gif\" alt=\"Wink\" width=\"15\" height=\"15\" />");

# copies the contents of the secont hash argument into the first.
sub hashmerge {
    my $hash1 = shift;
    my $hash2 = shift;

    my $key;
    foreach $key (keys %$hash2) {
        $hash1 -> {$key} = $hash2 -> {$key};
    }
}

sub text_to_html {
    my $text = shift;

    $text =~ s/\n\n/<\/p><p>/gm;
    $text =~ s/\n/\<br\>\n/gm;
    $text =~ s/<\/p><p>/<\/p>\n\n<p>/gm;
    
    return $text;
}


sub fix_entities {
    my $text = shift;

    # replace the four common character entities (note well: order is important, do not
    # replace & after " < or >
    if($text) {
        for($text) {
            s/&/&amp;/g;
            s/\"/&quot;/g;
            s/\</&lt;/g;
            s/\>/&gt;/g;
        }
    }

    return $text;
}


sub fix_all_entities {
    my $hashref = shift;
    my $key;

    foreach $key (keys %$hashref) {
        $hashref -> {$key} = fix_entities($hashref -> {$key});
    }

}


sub url_decode 
{
    my $url  = shift;
    my $text = shift;

    if($url =~ /(http:\/\/)?([\w\.]+).*/) {
        return "<a href=\"$url\">$text</a> [$2]";
    } else {
        return "<a href=\"$url\">$url</a>";
    }
}


sub bbcode_to_html {
    my $body = shift;

    # split lines without spaces...
    $body =~ s/(\S{75})/$1\n/gm;
    
    # simple tag conversion
    my $tag;
    foreach $tag (keys %tags) {
        $body =~ s/\[$tag\](.*?)\[\/$tag\]/\<span class\=\"$tags{$tag}\"\>$1<\/span>/gims;
    }
    $body =~ s/\[\*\]/<li>/gim;

    # more complex tags
    $body =~ s/\[code\](.*?)\[\/code\]/<table class="codebox"><tr><td><span class="nav">Code:<\/span><\/td><\/tr><tr><td class="codeblk">$1<\/td><\/tr><\/table>/gism;
    $body =~ s/\[quote\=&quot;(.+)&quot;\](.*?)\[\/quote\]/<table class\="codebox"><tr><td><span class="nav">Posted by $1:<\/span><\/td><\/tr><tr><td class\="quoteblk">$2<\/td><\/tr><\/table>/gism;
    $body =~ s/\[quote\](.*?)\[\/quote\]/<table class\="codebox"><tr><td><span class="nav">Quote:<\/span><\/td><\/tr><tr><td class\="quoteblk">$1<\/td><\/tr><\/table>/gism;
    
    $body =~ s/\[url\=(.+)\](.*?)\[\/url\]/url_decode($1, $2)/gisem;        
    $body =~ s/\[url\](.*?)\[\/url\]/<a href=\"$1\">$1<\/a>/gism;        

    $body =~ s/\[list=([1aAiI]{1})\](.*?)\[\/list\]/<ol class=\"list$1\">$2<\/ol>/gsim;
    $body =~ s/\[list\](.*?)\[\/list\]/<ul>$1<\/ul>/gsim;
                                         
    $body =~ s/\[img\](.*?)\[\/img\]/<img src="$1"\/>/gsim;

    $body =~ s/\[size=(\d+)\](.*?)\[\/size\]/<span style="font-size: $1px; line-height: normal">$2<\/span>/gsim;
    $body =~ s/\[color=([\#\w]+)\](.*?)\[\/color\]/<span style="color: $1;">$2<\/span>/gsim;

    $body =~ s/^---\s+/<hr class="divider"\/>/gm;

    # smilies
    foreach $tag (keys %smilies) {
        $body =~ s/\Q$tag\E/$smilies{$tag}/g;
    }

    # convert multilines to paragraphs.
    #$body =~ s/\n\n/<\/p><p>/go;

    # individual lines to linebreaks.
    $body =~ s/\n/<br\/>\n/go;

    return $body;
}


# Restricts the returned string to a specific length, specific number of lines
# or both.
sub limit_length {
    my ($string, $maxlen, $maxlines) = @_;

    # If the string is within length, return it unchanged
    my $lengthok = 1;
    $lengthok = (length($string) <= $maxlen) if($maxlen);
    
    # Less lines than the limit in the string?
    my $linesok = 1;
    my @newlines = $string =~ /(^)/gm;
    $linesok = (scalar(@newlines) <= $maxlines) if($maxlines);
    
    # return the string unchanged if the linecount and length are okay 
    return $string if($lengthok && $linesok);

    # Okay, one or both restriction failed. Work out which...
    if(!$linesok) {
        my @lines = $string =~ /^(.*)$/gm; # split by line discarding newlines
        $string = join("\n", splice(@lines, 0, $maxlines)); # rebuild the lines with \n between them (no trailing \n!!)
        $lengthok = (length($string) <= $maxlen) if($maxlen); # recheck the length to see if we've dropped below the limit        
    }

    if(!$lengthok) {
        # if the length isn't okay, truncate and add an ellipsis
        $string = substr($string, 0, $maxlen - 3)."...";
    }

    return $string;
}
    

# Load a template from a file and replace the tags in it with the values given
# in a hashref, return the string containing the filled-in template. The first
# argument should be the filename of the template, the second should be the
# hashref containing the key-value pairs. The keys should be the tags in the
# template to replace, the values should be the text to replace those keys 
# with. Tags can be any format and may contain regexp reserved chracters.
sub load_complex_template {
    my $name  = shift;
    my $elem_hashref = shift;

    if(open(TEMPLATE, $name)) {
        undef $/;
        my $lines = <TEMPLATE>;
        $/ = "\n";
        close(TEMPLATE);
       
        # replace all the keys in the doc with the appropriate value.
        if($elem_hashref) {
            my ($key, $value);
            foreach $key (keys %$elem_hashref) {
                $value = $elem_hashref -> {$key};
                $value = "" if(!defined($value)); # avoid "Use of uninitialized value in substitution" problems
                $lines =~ s/\Q$key\E/$value/g;
            }
        }
        return $lines;
    } else {
        print STDERR "*** load_complex_template: Error opening $name - $!\n";
        return "<p>load_complex_template: Error opening $name - $!</p>";
    }

}


# like load_complex_template except that this one will surround keys in ***
# so that the keys supplied in the variable bindings will not require the
# ***.  
sub load_complex_template_escape {
    my $name = shift;
    my $elem_hashref = shift;

    if(open(TEMPLATE, $name)) {
        undef $/;
        my $lines = <TEMPLATE>;
        $/ = "\n";
        close(TEMPLATE);
       
        # replace all the keys in the doc with the appropriate value.
        my ($key, $value);
        foreach $key (keys %$elem_hashref) {
            $value = $elem_hashref -> {$key};
            $value = "" if(!defined($value)); # avoid "Use of uninitialized value in substitution" problems
            $lines =~ s/\*\*\*$key\*\*\*/$value/g;
        }

        return $lines;
    } else {
        print STDERR "*** load_complex_template_escape: Error opening $name - $!\n";
        return "<p>load_complex_template_escape: Error opening $name - $!</p>";
    }

}


# Load a file into memory, do not process it, do not collect £200. Just a means 
# to load predefined html into a string to blast out to the user's browser as 
# part of a larger page generation incantation.
sub load_template {
    my $name = shift;

    if(open(TEMPLATE, $name)) {
        undef $/;
        my $lines = <TEMPLATE>;
        $/ = "\n";
        close(TEMPLATE);

        return $lines;
    }
    print STDERR "*** load_template: Error opening $name - $!\n";
    return "<p>load_template: Error opening $name - $!</p>";
}


# Wrapper for load_complex_template that will immediately print the processed
# template to stdout rather than pass it back to the caller in a string.
sub write_complex_template {
    my $name         = shift;
    my $theme        = shift;
    my $elem_hashref = shift;

    print load_complex_template($name, $theme, $elem_hashref);
}


sub build_select {
    my $options = shift;
    my $default = shift;
    my $result;

    my $key;
    foreach $key (sort keys %$options) {
        $result .= "<option value=\"$key\"";
        if($default && ($key eq $default)) { $result .= " selected=\"selected\""; }
        $result .= ">".$options -> {$key}."</option>\n";
    }

    return $result;
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

# ============================================================================
#  Time support
#

my @months = ("Foo", "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec");

# converts a string of the format "Day Mon DD, YYYY HH:MM am" to the number of
# seconds since the epoch. 
sub string_to_seconds {
    my $source = shift;

    if($source =~ /\s*\w+ (\w+) (\d+), (\d+) (\d+):(\d+) (\w+)/) {
        my ($month, $day, $year, $hours, $minutes, $ampm) = ($1, $2, $3, $4, $5, $6);
        
        # convert month to numeric
        my $i;
        for($i = 0; $i < scalar(@months) && $months[$i] ne $month; ++$i) { } 

        if($months[$i] eq $month) {
            $month = $i;
            
            # correct hours
            $hours += 12 if($ampm eq "pm");

            # convert it all to seconds...
            return timelocal(0, $minutes, $hours, $day, $month, $year);
        }
    }

    write_log("internal", "Utils::string_to_seconds(): WARNING: bad date format provided, unable to parse $source"); 
    return 0;
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
