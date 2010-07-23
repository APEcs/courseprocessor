#!/usr/bin/perl -w

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
#
# PEVE course processor, front-end and dispatcher
# 
# @version 3.7.0 (26 March 2010)

use strict;
use FindBin;             # Work out where we are
my $path;
BEGIN {
    # $FindBin::Bin is tainted by default, so we need to fix that
    if ($FindBin::Bin =~ /(.*)/) {
        $path = $1;
    }
}

use lib ("$path/modules", "$path/plugins"); # Add the script path for module loading
use File::HomeDir;
use Pod::Usage;
use Getopt::Long;
use ConfigMicro;
use Utils qw(check_directory resolve_path log_print fatal_setting);

use constant VERSION => "3.7 (26 March 2010) [Course Processor v3.7.0 (26 March 2010)]";

# Attempt to load the processor configuration file from the user's homedir.
# If it does not exist, exit returning undef.
# Recognised settings:
# outputhandler 
#     name = <handlername>
#     templates = <templatedir>
# referencehandler 
#     name = <handlername>
sub load_config {
    
    # Obtain the user's home directory
    my $home = File::HomeDir -> my_home;

    # does the configuration file exist?
    if(-e "$home/.courseprocessor.cfg") {
        my $config   = ConfigMicro -> new();
        my $settings = $config -> read("$home/.courseprocessor.cfg");

        if($settings) {
            return ($settings -> {"outputhandler"} -> {"name"},
                    $settings -> {"outputhandler"} -> {"templates"},
                    $settings -> {"referencehandler"} -> {"name"});
        }
        
    } 

    return (undef, undef, undef);
}


# Prints an error message about missing arguments and tells the
# user to provide them.
sub setting_error {
    my ($argument, $parameter, $configopt) = @_;

    print STDERR "$argument not set. Please provide a value for this setting using\nthe $parameter command line argument.\n";
    print STDERR "Alternatively, set the $configopt option in the\n configuration file located at~/.courseprocessor.cfg\n" if($configopt);
}


# Initial verbosity level: 0 = FATALs, 1 = NOTICE, 2 = WARN, 3 = DEBUG.
my $verbosity = 0;

# Debug output: 0 = disabled, 1 = enabled
my $debug = 0;

# Declare variables for the configuration and command line options.
my ($handler, $templatedir, $refhandler) = load_config();

# Variables that can be set in the command line
my ($datasource, $framework, $outputdir);
my ($man, $help, $listhandlers);

print "PEVE Course Processor version ",VERSION," started.\n";

# Call Getopt::Long to handle the options processing
GetOptions('verbose+'     => \$verbosity,
           'debug+'       => \$debug,
           'coursedata=s' => \$datasource,
           'framework=s'  => \$framework,
           'dest=s'       => \$outputdir,
           'outhandler:s' => \$handler,
           'templates:s'  => \$templatedir,
           'refhandler:s' => \$refhandler,
           'listhandlers' => \$listhandlers,
           'help|?'       => \$help,
           'man'          => \$man) or pod2usage(2);

pod2usage(1) if($help);
pod2usage(-exitstatus => 0, -verbose => 2) if $man;

# Dump the blargh status for reference
my $level = fatal_setting() ? "fatal" : "not fatal";
log_print($Utils::DEBUG, $verbosity, "Blarghs are $level");

# Fix high debug levels, and dump debugging status
$debug = 1 if($debug > 1);
log_print($Utils::DEBUG, $verbosity, "Debugging mode is $debug");

# this is a hashref storing the plugin object handles.
my $plugins;

# load available plugins from the plugin directory.
no strict 'refs'; # can't have strict refs on during plugin loading.
my $plugin;
while($plugin = glob("$path/plugins/*.pm")) {
    log_print($Utils::DEBUG, $verbosity, "Detected plugin $plugin, attempting to load...");
    $plugin =~ m|^$path/plugins/(\w+).pm$|; # obtain the plugin name 
    require $1.".pm";                 # load it
    my $htype = &{$1."::get_type"};   # obtain the handler type name
    
    log_print($Utils::DEBUG, $verbosity, "loaded, adding '",&{$1."::get_description"},"' as $htype handler\n");

    $plugins -> {$htype} -> {$1} -> {"obj"} = $1 -> new("verbose" => $verbosity, "debug" => $debug, "path" => $path); # create an object and store it
}
use strict;

if($listhandlers) {
    print STDERR "Available inputhandlers are:\n";
    foreach $plugin (sort(keys(%{$plugins -> {"input"}}))) {
        print STDERR "    ",$plugin,"\n";
    }
    print STDERR "Available outputhandlers are:\n";
    foreach $plugin (sort(keys(%{$plugins -> {"output"}}))) {
        print STDERR "    ",$plugin,"\n";
    }
    print STDERR "Available reference are:\n";
    foreach $plugin (sort(keys(%{$plugins -> {"ref"}}))) {
        print STDERR "    ",$plugin,"\n";
    }
    exit;
}

# check that all the variables needed have values
# The first three Should Not Happen.
setting_error("Course data directory", "--coursedata") if(!$datasource);
setting_error("Course framework dir" , "--framework")  if(!$framework);
setting_error("Output directory"     , "--dest")       if(!$outputdir);

# last chance fallbacks for situations where only a single handler exists
if(!$handler) {
    if(scalar(keys(%{$plugins -> {"output"}})) == 1) {
        $handler = (keys(%{$plugins -> {"output"}}))[0];
        log_print($Utils::WARNING, $verbosity, "OutputHander not specified, falling back on $handler");
    }
}
setting_error("Output handler"   , "--outhandler") if(!$handler);

# Disable the reference processing if there is no reference handler specified.
if(!$refhandler) {
    log_print($Utils::NOTICE, $verbosity, "No reference handler specified, disabling references generation");
    $refhandler = "none";
}

#print out the usage if any variable is empty
pod2usage(2) if(!$datasource || !$framework || !$outputdir || !$handler || !$refhandler);

# ensure the paths are really absolute
$datasource = resolve_path($datasource);
$framework  = resolve_path($framework);
$outputdir  = resolve_path($outputdir);

# Dump the input/output names for reference
log_print($Utils::DEBUG, $verbosity, "Using data directory     : $datasource");
log_print($Utils::DEBUG, $verbosity, "Using framework directory: $framework");
log_print($Utils::DEBUG, $verbosity, "Using output directory   : $outputdir");
 
# Verify that the source dirs /are/ dirs
check_directory($datasource, "course data source directory");
check_directory($framework , "course framework directory");
check_directory($outputdir , "output directory", 0, 1, 0);


# check that the output handler actually exists, if not print an error and list of handlers.
if(!defined($plugins -> {"output"} -> {$handler} -> {"obj"})) {
    print STDERR "FATAL: The specified output handler does not exist. Please check the name and try again\n";
    print STDERR "Available outputhandlers are:\n";
    foreach $plugin (sort(keys(%{$plugins -> {"output"}}))) {
        print STDERR $plugin,"\n" if(defined($plugins -> {"output"} -> {$plugin} -> {"obj"}));
    }
    exit;
}


# check which input plugins can run
my $canrun = 0;
foreach $plugin (sort(keys(%{$plugins -> {"input"}}))) {
    log_print($Utils::DEBUG, $verbosity, "Checking whether $plugin can be applied to the source... ");
    $plugins -> {"input"} -> {$plugin} -> {"use"} = $plugins -> {"input"} -> {$plugin} -> {"obj"} -> use_plugin($datasource);
    $canrun++ if($plugins -> {"input"} -> {$plugin} -> {"use"});
    log_print($Utils::DEBUG, $verbosity, $plugins -> {"input"} -> {$plugin} -> {"use"} ? "Yes" : "No");
}

# if none of the input handlers understand the source, half with an error
if(!$canrun) {
    print STDERR "FATAL: the course data is not recognised by any of the input handlers.\n";
    print STDERR "FATAL: unable to run any plugins on the course data, giving up.\n";
    print STDERR "Available inputhandlers are:\n";
    foreach $plugin (sort(keys(%{$plugins -> {"input"}}))) {
        print STDERR $plugin," - ",$plugins -> {"input"} -> {$plugin} -> {"obj"} -> get_description(),"\n" if(defined($plugins -> {"input"} -> {$plugin} -> {"obj"}));
    }
    exit;
}


# check that the output plugin could run. The handler *should* die if it can't run, but catch it anyway
log_print($Utils::DEBUG, $verbosity, "Checking output plugin can be run...");
die "FATAL: The selected output plugin may not be usable on the course tree, bombing."
    if(!$plugins -> {"output"} -> {$handler} -> {"obj"} -> use_plugin($datasource, $templatedir, $plugins));


# remove the old output if it exists and replace it with a copy of the source
# need to use rm -rf because unlink / rmdir won't help here...
log_print($Utils::DEBUG, $verbosity, "Removing old output directory.");
`rm -rf $outputdir`;

log_print($Utils::DEBUG, $verbosity, "Copying source data.");
`cp -r $datasource $outputdir`;

# Run the input plugins that say they can be used...
foreach $plugin (sort(keys(%{$plugins -> {"input"}}))) {
    if($plugins -> {"input"} -> {$plugin} -> {"use"}) {
        print "Running $plugin on the course data\n";
        $plugins -> {"input"} -> {$plugin} -> {"obj"} -> process($outputdir);
    }
}


# Now run the output plugin. Note that the output handler is responsible
# for merging the contents of the framework directory into the output.
print "Running $handler on the course data\n";
$plugins -> {"output"} -> {$handler} -> {"obj"} -> process($outputdir, $framework, $refhandler);


log_print($Utils::DEBUG, $verbosity, "Processing complete");

__END__

=head1 NAME

courseprocessor - convert a tree of files into a templated course

=head1 SYNOPSIS

=over 12

=item B<processor> 

[B<-vl>] 
[B<--help>] 
[B<--man>] 
[B<--debug>]
[B<-o>S< >I<outputhandler>] 
[B<-t>S< >I<templates>] 
[B<-r>S< >I<refhandler>] 
B<-c>S< >I<coursedata>
B<-f>S< >I<framework>
B<-dest>S< >I<outputdir>

=head1 OPTIONS

=over 8

=item B<--verbose> B<-v> 

Increase the output verbosity. This may be repeated several times to increase
the verbosity level. -v -v -v would enable all levels of output, including debug.

=item B<--debug>

Enable debugging mode. Prevents the removal of temporary files, and enables
additional output.

=item B<--listhandlers> B<-l>

Lists the available input, output and reference handlers and then exit.

=item B<--coursedata> B<-c> I<coursedatadir>

Sets the course data source directory. This argument is not optional, and the
processor will exit with an error if it is not supplied.

=item B<--framework> B<-f> I<frameworkdir>

Specifies the course framework directory. This argument is not optional, and 
the processor will exit with an error if it is not supplied.

=item B<--dest> I<outputdir>

Specifies the name of the directory into which the course should be processed.
NOTE: if this directory exists B<it will be deleted during processing>. Take
great care to ensure that the output directory does not contain any 
pre-existing data as the processed course will completely overwrite it.

=item B<--outhandler> B<-o> I<outputhandler>

Overrides the outputhandler specified in the configuration file (if there is
one). Note that this must be the full name of an outputhandler loaded by 
the software and it is case sensitive. Use B<-l> to obtain the list of known
handlers for valid values.

=item B<--templates> B<-t> I<templatedir>

Overrides the template directory given in the configuration file. This is
case sensitive and, unless the path is absolute, it is relative to the 
directory given in the PROCESSOR_HOME environment variable.

=item B<--refhandler> B<-r> I<referencehandler>

Overrides the reference handler specified in the configuration file. This 
is case sensitive and must correspond to a reference handler loaded by
the software. Use B<-l> to obtain a list of known handlers for valid
values.

=item B<--help> B<-h> B<-?>

Print a brief help message and exits.

=item B<--man> B<-m>

Prints the manual page and exits.

=back

=head1 DESCRIPTION



=cut
