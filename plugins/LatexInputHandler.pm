package LatexInputHandler;

# Convert a course consisting of LaTeX documents into the intermediate
# format expected by the output handlers.

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

# IMPORTANT FOR v3.7: HTMLOutputHandler has been modified to remove all
# specific format support (ie: the code to make up for latex2html's odd output 
# has been removed). This plugin needs to be updated to compensate for this,
# in particular:
#
# - removing <h\d>step titles</h\d> from steps
# - removing trailing <hr> from steps
# - fixing crossref icons (s{file:/usr/lib/latex2html/icons/crossref.png}{../../images/crossref.png}gi;)
# - fixing escaped links (s/&lt;a\s+href="(.*?)"\s*&gt;/<a href="$1">/gi; s/&lt;\/a&gt;/<\/a>/gi;)
#
# For diff, see commit d931230084bfd5a191347a327de87ff4a54b3f13

require 5.005;
use Cwd qw(getcwd chdir);
use Utils qw(load_file log_print blargh);
use Digest::MD5 qw(md5_hex);
use strict;

my ($VERSION, $type, $errstr, $htype, $extfilter, $desc, $cleanup);

BEGIN {
	$VERSION       = 1.0;
    $htype         = 'input';                 # handler type - either input or output
    $extfilter     = '\.tex$';                # files matching this are assumed to be understood for processing.
    $desc          = 'Latex input processor'; # Human-readable name
	$errstr        = '';                      # global error string
    $cleanup       =  1;                      # set to 0 to disable removal of source and intermediate files.
}

# ============================================================================
#  Constructor and identifier functions.  
#   
sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;

    my $self     = {
        "cmd"        => "/usr/bin/latex2html",                     # the location of latex2html, make it absolute - do not rely on the path!
        "args"       => '-nonavigation -noaddress -white -noinfo -antialias_text -html_version "4.1"', # options to pass to latex2html
        "latexintro" => 'latexintro.txt',                          # name of the file containing latex header info 
        "verbose"    => 0,                                         # set to 1 to enable additional output
        @_
    };

    return bless $self, $class;
}

# Top level handler type ID
sub get_type { return $htype };

# Handler descriptive text
sub get_description { return $desc };

# Handler version number
sub get_version { return $VERSION };

# Extension matcher
sub get_extfilter { return $extfilter };


# ============================================================================
#  Precheck - can this plugin be applied to the source tree?
#   

# Determine whether this plugin should be run against the source tree by looking for
# files it recognises how to process in the directory structure.
sub use_plugin {
    my $self   = shift;
    my $srcdir = shift;
    my $usemod = 0; # gets set > 1 if there are any files this plugin understands.

    # This should be the top-level "source data" directory, should contain theme dirs
    opendir(SRCDIR, $srcdir)
        or die "FATAL: Unable to open source directory for reading: $!";

    # grab the directory list so we can check it for subdirs, strip .* files though
    my @srcentries = grep(!/^\./, readdir(SRCDIR));
    
    foreach my $entry (@srcentries) {
        $entry = "$srcdir/$entry";

        # if this is a directory, check inside for known extensions
        if(-d $entry) {
            opendir(SUBDIR, $entry)
                or die "FATAL: Unable to open source subdir for reading: $!";
            
            # grep returns the number of matches in scalar mode and that's all we
            # really want to know at this point
            $usemod += grep(/$extfilter/, readdir(SUBDIR));
 
            closedir(SUBDIR);
        }
    }

    closedir(SRCDIR);

    return $usemod;
}


# Check whether the module specified is valid and usable by this plugin
# return a string containing an error message if there is a problem, 0 otherwise.
sub module_check {
    my $self     = shift;
    my $themedir = shift;
    my $name     = shift;

    # does the latex file for the specified module exist?
    return "LatexInputHandler: Module $name does not have a corresponding .tex file." unless(-e "$themedir/$name.tex");

    # ensure it is a file, not a directory
    return "LatexInputHandler: $themedir/$name.tex is a directory, not a normal file or symlink." if(-d "$themedir/$name.tex");

    # and it is readable
    return "LatexInputHandler: $themedir/$name.tex is not readable." unless(-r "$themedir/$name.tex");

    # there's a good chance, if we get here, that it's okay.
    return 0;
}


# ============================================================================
#  File handling code
#   

# Ensure that the required directories are present in the filesystem This is
# somewhat wasteful if the processing results in no latex image generation
# events, but it probably isn't worth any complex code to avoid it.
sub check_image_dirs {
    my $base = shift;

    mkdir "$base/images" if(!-e "$base/images");
    mkdir "$base/images/generated" if(!-e "$base/images/generated");
}


# ============================================================================
#  Process code
#   

sub process {
    my $self = shift;
    my $srcdir = shift;
    my @badfiles;

    # This should be the top-level "source data" directory, should contain theme dirs
    opendir(SRCDIR, $srcdir)
        or die "FATAL: Unable to open source directory for reading: $!";

    # ensure we have output dirs we need
    check_image_dirs($srcdir);

    # grab the directory list so we can check it for subdirs, strip .* files though
    my @srcentries = grep(!/^\./, readdir(SRCDIR));
    
    foreach my $entry (@srcentries) {
        $entry = "$srcdir/$entry";

        log_print($Utils::DEBUG, $self -> {"verbose"}, "Scanning $entry for files");

        # if this is a directory, check inside for known extensions
        if(-d $entry) {
            opendir(SUBDIR, $entry)
                or die "FATAL: Unable to open source subdir for reading: $!";
            
            # now grab a list of files we know how to process, then call the internal process
            # function for each one, remembering to include the full path.
            my @subfiles = grep(/$extfilter/, readdir(SUBDIR));
            
            if(scalar(@subfiles)) {
                my $cwd = getcwd();
                chdir($entry);

                # process the files in the theme directory
                foreach my $subentry (@subfiles) {
                    log_print($Utils::DEBUG, $self -> {"verbose"}, "Processing $subentry");
                    my @bad = $self -> internal_process($subentry, $srcdir);
                    push(@badfiles, [ @bad ]) if(scalar(@bad));
                    log_print($Utils::DEBUG, $self -> {"verbose"}, "Finished processing $subentry");
                }
                chdir($cwd);
            }

            closedir(SUBDIR);
        }
    }

    closedir(SRCDIR);

    # list any files that contained problems.
    log_print($Utils::DEBUG, $self -> {"verbose"}, "Completed latex processing");
    if(scalar(@badfiles)) {
        log_print($Utils::WARNING, $self -> {"verbose"}, "Following files contain malformed section\\subsection data:");
        foreach my $file (@badfiles) {
            print "$file\n";
        }
    } else {
        log_print($Utils::DEBUG, $self -> {"verbose"}, "All files are okay");
    }

    `rm -f $srcdir/latexintro` if($cleanup);

    return 1;
}


# remove any junk files files from the output directory, leaves generated images
# and html pages intact.
sub cleanup {
    my $self = shift;
    my $modname = shift;

    log_print($Utils::DEBUG, $self -> {"verbose"}, "Cleaning up temporary files in $modname");
    `rm -f $modname.css`;
    `rm -f $modname.html`;
    `rm -f images.*`;
    `rm -f index.html`;
    `rm -f labels.pl`;
}

# latex2html generates a cover page in node1.html, this is useless to us so we
# need to shift the later pages down by one.
sub remove_node1 {
  
    my $num = 2;
    while(-e "node$num.html") {
        my $prev = $num - 1;
        `mv node$num.html node$prev.html`;
        ++$num;
    }
}


sub internal_process {
    my $self     = shift;
    my $filename = shift;
    my $base     = shift;
    my @badfiles;

    # Before we can process, we need to prepend the latex file with the intro
    my $intro = load_file($base."/".$self -> {"latexintro"})
        or die "FATAL: Unable to open latexintro: $!";
    
    my $data  = load_file($filename)
        or die "FATAL: Unable to open latex file $filename: $!";

    # ensure the data contains unix newlines only
    $data =~ s/\r//g;

    # fix files that have no section but subsections (WTF?!?!?!?)
    if($data =~ /^\s*\\subsection/si) {
        $data =~ s/^\s*\\subsection(\*?){(.*?)}/\\section*{$2}\n\\subsection*{$2}/si;
        blargh("Detected missing section in $filename - FIX THIS FILE!");
        push(@badfiles, $filename);
    }
    # fix files that have section but no subsections
    if($data !~ /^\s*\\section(\*?){.*?}\s*\\subsection/si) {
        $data =~ s/^\s*\\section(\*?){(.*?)}/\\section*{$2}\n\\subsection*{$2}/si;
        blargh("Detected malformed section\\subsection in $filename - FIX THIS FILE!");
        push(@badfiles, $filename);
    }
    
    # Save the latex introduction and processed body over the source file. 
    open(OUTPUT, "> $filename")
        or die "FATAL: Unable to write latex file $filename: $!";
    print OUTPUT $intro, "\n\\begin{document}\n", $data,"\\end{document}\n";
    close(OUTPUT);

    # Now do the processing.
    my $cmd = $self -> {"cmd"}." ".$self -> {"args"}." ".$filename;
    my $output = `$cmd`;
    if($output =~ /Error while converting image/) {
        print $output;
        die "FATAL: Errors encountered while running latext2html";
    }

    print $output if($self -> {"verbose"} > 1);

    # now do postprocessing k - first we need the name without the .tex extension
    my $name;
    if($filename =~ /^(.*).tex$/) {
        $name = $1;

        # go into the directory latex2html generated
        my $cwd = getcwd();
        chdir($name);

        # Remove anything that isn't nodeN.html
        $self -> cleanup($name) if($cleanup);

        # correct for spurious node1.html generation
        $self -> remove_node1();
        
        # move generated images
        my $fullnamesum = md5_hex("$cwd/$name");
            
        while(my $imgname = glob("$cwd/$name/img*.png")) {
            $imgname =~ /img(\d+)\.(\w+)/;
            
            my $dest = "$base/images/generated/$fullnamesum-img$1\.$2";

            log_print($Utils::DEBUG, $self -> {"verbose"}, "Copying and cropping $imgname as $dest");
            # old move: `mv -f $name $dest`;

            die "FATAL: name clash when processing $imgname to $dest, destination exists! This Should not Happen!"
                if(-e $dest);

            # the following line theoretically removes spurious bottom black bars
            # hopefully this won't screw up real boxing...
            `pngtopnm $imgname | pnmcrop -black | pnmtopng -transparent "#B3B3B3" > $dest`;
            `rm -f $imgname`;
        }
        
        # now correct the image links in the nodes
        while(my $htmlname = glob("node*.html")) {
            log_print($Utils::DEBUG, $self -> {"verbose"}, "Correcting generated image links in $cwd/$name/$htmlname");
            open(INFILE, $htmlname)
                or die "FATAL: Unable to read $htmlname for postprocessing: $!";
            undef $/;
            my $content = <INFILE>;
            $/ = "\n";
            close(INFILE);

            $content =~ s{src="img(\d+).png"}{src="../../images/generated/$fullnamesum-img$1.png"}gis;

            open(OUTFILE, "> $htmlname")
                or die "FATAL: Unable to write $htmlname during postprocessing: $!";
            print OUTFILE $content;
            close(OUTFILE);
        }

        # drop back to the higher directory
        chdir($cwd);
    }

    # remove the source latex file
    `rm -f $filename` if($cleanup);
 
    return @badfiles;
}

# modules must always end with this
1;
