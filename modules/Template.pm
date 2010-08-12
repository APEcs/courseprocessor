## @file
# This file contains the implementation of the template engine.
#
# @author  Chris Page &lt;chris@starforge.co.uk&gt;
# @version 1.0
# @date    23 November 09
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

## @class Template
# A simple Template class with internationalisation support. Note that
# this class does not cache templates or any fancy stuff like that - it
# just provides a simple interface to generate content based on
# replacing markers in files.
package Template;

use Logging;
use POSIX qw(strftime);
use Utils qw(path_join superchomp);
use strict;

our ($VERSION, $errstr, $utfentities, $entities);

BEGIN {
	$VERSION = 1.0;
	$errstr = '';
    
    $utfentities = { '\xC2\xA3'     => '&pound;',
                     '\xE2\x80\x98' => '&lsquo;',
                     '\xE2\x80\x99' => '&rsquo;',
                     '\xE2\x80\x9C' => '&ldquo;',
                     '\xE2\x80\x9D' => '&rdquo;',
                     '\xE2\x80\x93' => '&ndash;',
                     '\xE2\x80\x94' => '&mdash;',
                     '\xE2\x80\xA6' => '&hellip;',
    };
    $entities = {'\x91' => '&lsquo;',  # 0x91 (145) and 0x92 (146) are 'smart' singlequotes
                 '\x92' => '&rsquo;',
                 '\x93' => '&ldquo;',  # 0x93 (147) and 0x94 (148) are 'smart' quotes
                 '\x94' => '&rdquo;',
                 '\x96' => '&ndash;',  # 0x96 (150) and 0x97 (151) are en and emdashes
                 '\x97' => '&mdash;',
                 '\x88' => '&hellip;', # 0x88 (133) is an ellisis
    };
}


# ============================================================================
#  Constructor and language loading

## @cmethod $ new(%args)
# Create a new Template object. This will create a new Template object that will
# allow templates to be loaded into strings, or printed to stdout. Meaningful
# arguments to this constructor are:
# basedir  - The directory containing template themes. Defaults to "templates". 
# langdir  - The directory containing language files. Defaults to "lang".
# lang     - The language file to use. Defaults to "en"
# theme    - The theme to use. Defaults to "default"
# timefmt  - The time format string, strftime(3) format. Defaults to "%a, %d %b %Y %H:%M:%S"
sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;

    # Object constructors don't get much more minimal than this...
    my $self = { "basedir" => "templates",
                 "langdir" => "lang",
                 "lang"    => "en",
                 "theme"   => "default",
                 "timefmt" => '%a, %d %b %Y %H:%M:%S',
                 "mailfmt" => '%a, %d %b %Y %H:%M:%S %z',
                 "mailcmd" => '/usr/sbin/sendmail -t -f chris@starforge.co.uk',#pevesupport@cs.man.ac.uk', # Change -f as needed!
                 @_,
    };

    my $obj = bless $self, $class;

    # Load the language definitions
    $obj -> load_language() or return undef;

    return $obj;
}


## @method void set_module_obj($modules)
# Store a reference to the module handler object so that the template loader can
# do block name replacements.
#
# @param modules A reference to the system module handler object.
sub set_module_obj {
    my $self = shift;
    
    $self -> {"modules"} = shift;
}


## @method $ load_language(void)
# Load all of the language files in the appropriate language directory into a hash.
# This will attempt to load all .lang files inside the langdir/lang/ directory,
# attempting to parse VARNAME = string into a hash using VARNAME as the key and string
# as the value. The hash is build up inside the Template object rather than returned.
#
# @return true if the language files loaded correctly, undef otherwise.
sub load_language {
    my $self = shift;

    # First work out which directory we are dealing with
    my $langdir = path_join($self -> {"langdir"}, $self -> {"lang"});

    # open it, so we can process files therein
    opendir(LANG, $langdir)
        or return set_error("Unable to open language directory '$langdir' for reading: $!");

    while(my $name = readdir(LANG)) {
        # Skip anything that doesn't identify itself as a .lang file
        next unless($name =~ /\.lang$/);
    
        my $filename = path_join($langdir, $name);

        # Attempt to open and parse the lang file
        if(open(WORDFILE, "<:utf8", $filename)) {
            while(my $line = <WORDFILE>) {
                superchomp($line);

                # skip comments
                next if($line =~ /^\s*#/);

                # Pull out the key and value, and 
                my ($key, $value) = $line =~ /^\s*(\w+)\s*=\s*(.*)$/;
                next unless(defined($key) && defined($value));
                
                # Unslash any \"s
                $value =~ s/\\\"/\"/go;

                # warn if we are about to redefine a word
                warn_log("Unknown", "$key already exists in language hash!") if($self -> {"words"} -> {$key});

                $self -> {"words"} -> {$key} = $value;
            }
            
            close(WORDFILE);
        }  else {
            warn_log("Unknown", "Unable to open language file $filename: $!");
        }
    }

    closedir(LANG);

    # Did we get any language data at all?
    return set_error("Unable to load any lanugage data. Check your language selection!")
        if(!defined($self -> {"words"}));

    return 1;
}


# ============================================================================
#  Templating functions

## @method $ replace_langvar($varname, $default, $varhash)
# Replace the specified language variable with the appropriate text string. This
# takes a language variable name and returns the value stored for that variable,
# if there is on. If there is no value available, and the default is provided,
# that is returned. If all else fails this just returns "&lt;$varname&gt;"
#
# @param varname The name of the language variable to obtain a value for.
# @param default An optional default value.
# @param varhash An optional reference to a hash containing key-value pairs, any
#                occurance of the key in the text string is replaced with the value.
# @return The value for the language variable, or the default if the value is not
#         available. If the default is not available either this returns the 
#         variable name in angled brackets.
sub replace_langvar {
    my $self    = shift;
    my $varname = shift;
    my $default = shift;
    my $varhash = shift;

    # Fix up the arguments - if default is a reference, then it's really the varhash
    # and default was omitted
    if(ref($default) eq "HASH") {
        $varhash = $default;
        
        # Make the default value be the variable name in red to hilight problems
        $default = "<span style=\"color: red\">$varname</span>";
    }

    # strip the leadin L_ if present
    $varname =~ s/^L_//o;

    if(defined($self -> {"words"} -> {$varname})) {
        my $txtstr = $self -> {"words"} -> {$varname};

        # If we have a hash of variables to substitute, do the substitute
        if($varhash) {
            foreach my $key (keys(%$varhash)) {
                my $value = defined($varhash -> {$key}) ? $varhash -> {$key} : ""; # make sure we get no undefined problems...
                $txtstr =~ s/\Q$key\E/$value/g;
            }
        }

        # Do any module marker replacements if we can
        if($self -> {"modules"}) {
            $txtstr =~ s/{B_\[(\w+?)\]}/$self->replace_blockname($1)/ge;
        }

        return $txtstr;
    }           
    
    return $default;
}


## @method $ replace_blockname($blkname, $default)
# Replace a block name with the internal ID for the block. This will replace
# a block name with the equivalent block ID and it can cope with the name 
# being embedded in B_[...] strings.
#
# @param blkname The name of the block to replace with a block id.
# @param default Optional default id to use if the block is not found.
# @return The id that corresponds to the specified block name.
sub replace_blockname {
    my $self    = shift;
    my $blkname = shift;
    my $default = shift || "0";

    # Strip the B_[ ] if present
    $blkname =~ s/^B_\[(.*)\]$/$1/;

    my $modid = $self -> {"modules"} -> get_block_id($blkname);

    return defined($modid) ? $modid : $default;
}


## @method $ load_template($name, $varmap)
# Load a template from a file and replace the tags in it with the values given
# in a hashref, return the string containing the filled-in template. The first
# argument should be the filename of the template, the second should be the
# hashref containing the key-value pairs. The keys should be the tags in the
# template to replace, the values should be the text to replace those keys
# with. Tags can be any format and may contain regexp reserved chracters.
#
# @param name   The name of the template to load.
# @param varmap A reference to a hash containing values to replace in the template.
# @return The template with replaced variables and language markers.
sub load_template {
    my $self   = shift;
    my $name   = shift;
    my $varmap = shift;

    my $filename = path_join($self -> {"basedir"}, $self -> {"theme"}, $name);

    if(open(TEMPLATE, "<:utf8", $filename)) {
        undef $/;
        my $lines = <TEMPLATE>;
        $/ = "\n";
        close(TEMPLATE);

        # Do variable substitution
        $self -> process_template(\$lines, $varmap);

        return $lines;
    } else {
        return "<span class=\"error\">load_template: error opening $filename: $!</span>";
    }
}


## @method $ process_template($text, $varmap)
# Perform variable substitution on the text. This will go through each key in the
# provided hashref and replace all occurances of the key in the text with the value
# set in the hash for that key.
#
# @param text    The text to process. If this is a reference, the replacement is 
#                done in-place, otherwise the modified string is returned.
# @param varmap  A reference to a hash containing variable names as keys, and the
#                values to substitute for the keys.
# @return undef if text was a reference, otherwise a copy of the modified string.
sub process_template {
    my $self    = shift;
    my $text    = shift;
    my $varmap  = shift;
    
    # If text is a reference already, we can just use it. Otherwise we need
    # to make a reference to the text to simplify the code in the loop below.
    my $textref = ref($text) ? $text : \$text;

    # replace all the keys in the text with the appropriate value.
    my ($key, $value);
    foreach $key (keys %$varmap) {
        # pull out the value if it is defined, blank otherwise - avoids "Use of uninitialized value in substitution" problems
        $value = defined($varmap -> {$key}) ? $varmap -> {$key} : "";
        $$textref =~ s/\Q$key\E/$value/g;
    }

    # Do any language marker replacements
    $$textref =~ s/{L_(\w+?)}/$self->replace_langvar($1)/ge;

    # Do any module marker replacements if we can
    if($self -> {"modules"}) {
        $$textref =~ s/{B_\[(\w+?)\]}/$self->replace_blockname($1)/ge;
    }

    # Convert some common utf-8 characters
    foreach my $char (keys(%$utfentities)) {
        $$textref =~ s/$char/$utfentities->{$char}/g;
    }

    # Convert horrible smart quote crap from windows
    foreach my $char (keys(%$entities)) {
        $$textref =~ s/$char/$entities->{$char}/g;
    }
    
    # Return nothing if the text was a reference to begin with, otherwise
    # return the text itself.
    return ref($text) ? undef : $text;
}


# ============================================================================
#  Higher-level templating functions

## @method $ message_box($title, $type, $summary, $longdesc, $additional)
# Create a message box block to include in a page. This generates a templated
# message box to include in a page. It assumes the presence of messagebox.tem
# in the template directory, containing markers for a title, type, summary,
# long description and additional data. The type argument should correspond
# to an image in the {template}/images/messages/ directory without an extension.
#
# @param title      The title of the message box.
# @param type       The message type.
# @param summary    A summary version of the message.
# @param longdesc   The full message body
# @param additional Any additional content to include in the message box.
# @return A string containing the message box.
sub message_box {
    my ($self, $title, $type, $summary, $longdesc, $additional) = @_;
    
    return $self -> load_template("messagebox.tem", { "***title***"      => $title,
                                                      "***icon***"       => $type,
                                                      "***summary***"    => $summary,
                                                      "***longdesc***"   => $longdesc,
                                                      "***additional***" => $additional });
}


## @method $ wizard_box($title, $type, $stages, $stage, $longdesc, $additional)
# Create a wizard box block to include in a page. This generates a templated
# wizard box to include in a page. It assumes the presence of wizardbox.tem
# in the template directory, containing markers for a title, type, path,
# long description and additional data. The type argument should correspond
# to an image in the {template}/images/messages/ directory without an extension.
#
# @param title      The title of the message box.
# @param type       The message type.
# @param stages     A reference to an array of hashes containing stages in the wizard.
# @param stage      The current stage number.
# @param longdesc   The message body to show below the stages.
# @param additional Any additional content to include in the wizard box (forms, etc)
# @return A string containing the wizard box.
sub wizard_box {
    my ($self, $title, $type, $stages, $stage, $longdesc, $additional) = @_;
    
    # Preload the step template
    my $steptem = $self -> load_template("wizardstep.tem");
    chomp($steptem);

    my $path = "";
    for(my $s = 0; $s < scalar(@$stages); ++$s) {
        # calculate some gubbins to make life easier...
        my $step = $stages -> [$s];
        my $mode;

        if($s < $stage) {
            $mode = "passed";
        } elsif($s > $stage) {
            $mode = "inactive";
        } else {
            $mode = "active";
        }

        # Now we need to generate the stage image, this should be simple...
        $path .= $self -> process_template($steptem, {"***image***"  => $step -> {$mode},
                                                      "***width***"  => $step -> {"width"},
                                                      "***height***" => $step -> {"height"},
                                                      "***alt***"    => $step -> {"alt"}});
    }

    return $self -> load_template("wizardbox.tem", { "***title***"      => $title,
                                                     "***icon***"       => $type,
                                                     "***path***"       => $path,
                                                     "***longdesc***"   => $longdesc,
                                                     "***additional***" => $additional });
}


# ============================================================================
#  Emailing functions


## @method $ email_template($template, $args)
# Load a template and send it as an email to the recipient(s) listed in the arguments.
# This function will load a template from the template directory, fill in the fields
# as normal, and prepend an email header using the to and cc fields in the args (bcc
# is not supported).
#
# @param template The name of the template to load and send.
# @param args     A reference to a hash containing values to substitute in the template.
#                 This MUST include 'from', 'to', and 'subject' values!
# @return undef on success, otherwise an error message.
sub email_template {
    my $self     = shift;
    my $template = shift;
    my $args     = shift;
    my $email;

    # Check we have required fields
    return "No from field specified in email template arguments."    if(!$args -> {"***from***"});
    return "No to field specified in email template arguments."      if(!$args -> {"***to***"});
    return "No subject field specified in email template arguments." if(!$args -> {"***subject***"});

    # Build the header first...
    $email  = "From: ".$args -> {"***from***"}."\n";
    $email .= "To: ".$args -> {"***to***"}."\n";
    $email .= "Cc: ".$args -> {"***cc***"}."\n" if($args -> {"***cc***"});
    $email .= "Subject: ".$args -> {"***subject***"}."\n";
    $email .= "Date: ".strftime($args -> {"***date***"})."\n" if($args -> {"***date***"});
    $email .= "\n";

    # now load and process the template
    $email .= $self -> load_template($template, $args);

    # And send the email
    return $self -> send_email_sendmail($email);
}


## @method $ send_email_sendmail($email)
# Send the specified email using sendmail. This will print the contents of the
# specified email over a pipe to sendmail, sending it to the recipient(s). The
# email should be complete, including any headers.
#
# @param email The email to send.
# @return undef if the mail was sent, otherwise an error message is returned.
sub send_email_sendmail {
    my $self = shift;
    my $email = shift;

    open(SENDMAIL, "|".$self -> {"mailcmd"})
        or return "send_email_sendmail: unable to open sendmail pipe: $!";
    print SENDMAIL $email
        or return "send_email_sendmail: error while printing email: $!";
    close(SENDMAIL);

    return undef;
}


# ============================================================================
#  Support functions

## @method $ get_bbcode_path(void)
# Obtain the path to the current template's bbcode translation file. If the path
# does not exist, this returns undef, otherwise it provides the path containing
# the bbcode translations.
#
# @return The filename of the bbcode translation file, or undef if it does not exist.
sub get_bbcode_path {
    my $self = shift;

    my $filename = path_join($self -> {"basedir"}, $self -> {"theme"});
    
    return (-d $filename) ? $filename : undef;
}


## @method $ format_time($time)
# Given a time un unix timestamp format (seconds since the epoc), create a formatted 
# date string.
#
# @param $time The time to format.
# @return The string containing the formatted time.
sub format_time {
    my $self = shift;
    my $time = shift;

    return strftime($self -> {"timefmt"}, localtime($time));
}


## @method $ html_clean($text)
# Process the specified text, converting ampersands, quotes, and angled brakets
# into xml-safe character entity codes.
#
# @param text The text to process.
# @return The text with &, ", < and > replaces with &amp;, $quot;, $lt;, and &gt;
sub html_clean {
    my $self = shift;
    my $text = shift;

    # replace the four common character entities (FIXME: support more entities)
    if($text) {
        $text =~ s/&(?!amp|quot|lt|gt)/&amp;/g; # only replace & if it isn't already prefixing a character entity we know
        $text =~ s/\"/&quot;/g;
        $text =~ s/\</&lt;/g;
        $text =~ s/\>/&gt;/g;
    }

    return $text;
}


## @method $ bytes_to_human($bytes, $long)
# Produce a human-readable version of the provided byte count. If $bytes is
# less than 1024 the string returned is in bytes. Between 1024 and 1048576 is
# in KB, between 1048576 and 1073741824 is in MB, over 1073741824 is in GB
#
# @param bytes The byte count to convert
# @param long  If set to true, use 'Bytes' instead of B in the output. Defaults to false.
# @return A string containing a human-readable version of the byte count.
sub bytes_to_human {
    my $self  = shift;
    my $bytes = shift;
    my $long  = shift;

    my $ext = $long ? "ytes" : "";

    if($bytes >= 1073741824) {
        return sprintf("%.2f GB$ext", $bytes / 1073741824);
    } elsif($bytes >= 1048576) {
        return sprintf("%.2f MB$ext", $bytes / 1048576);
    } elsif($bytes >= 1024) {
        return sprintf("%.2f KB$ext", $bytes / 1024);
    } else {
        return "$bytes B$ext";
    }
}


## @fn $ humanise_seconds($seconds)
# Convert a number of seconds to days/hours/minutes/seconds. This will take 
# the specified number of seconds and output a string containing the number 
# of days, hours, minutes, and seconds it corresponds to.
#
# @param seconds The number of seconds to convert.
# @return A string containing the seconds in a human readable form
sub humanise_seconds {
    my $self = shift;
    my $seconds = shift;
    my ($frac, $mins, $hours, $days);
    my $result = "";

    ($frac)  = $seconds =~ /\.(\d+)$/;
    $days    = int($seconds / (24 * 60 * 60));
    $hours   = ($seconds / (60 * 60)) % 24;
    $mins    = ($seconds / 60) % 60;
    $seconds = $seconds % 60;

    if($days) { 
        $result .= $days." day".($days  > 1 ? "s" : "");
    }

    if($hours) {
        $result .= ", " if($result);
        $result .= $hours." hour".($hours > 1 ? "s" : "");
    }

    if($mins) {
        $result .= ", " if($result);
        $result .= $mins." minute".($mins  > 1 ? "s" : "");
    }

    if($seconds) {
        $result .= ", " if($result);
        $result .= $seconds.($frac ? ".$frac" : "")." seconds".($mins  > 1 ? "s" : "");
    }

    return $result;
}


# ============================================================================
#  Error functions

sub set_error { $errstr = shift; return undef; }

1;
