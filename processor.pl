#!/usr/bin/perl -w

# APEcs course processor, front-end and dispatcher. This script is the core of
# the APEcs course processor, it handles command line and configuration loading,
# loading of the various input and output handler plugins, and invocation of 
# the appropriate plugins over the course material to do the actual work.
# 
# @version 3.7.12 (4 November 2010)
# @copy 2010, Chris Page &lt;chris@starforge.co.uk&gt;
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

use strict;
use utf8;

use FindBin;             # Work out where we are
my $path;
BEGIN {
    # $FindBin::Bin is tainted by default, so we need to fix that
    if ($FindBin::Bin =~ /(.*)/) {
        $path = $1;
    }
}

# System modules
use File::HomeDir;
use Pod::Usage;
use Getopt::Long;

# Local modules
use lib ("$path/modules"); # Add the script path for module loading
use ConfigMicro;
use Filter;
use Logger;
use Metadata;
use ProcessorVersion;
use Template;
use Utils qw(check_directory resolve_path path_join);


## @fn $ handle_commandline(void)
# Parse the command line into a hash, and invoke pod2usage if the appropriate
# options are specified. This will not confirm whether or not required arguments
# are present; that must be done by the caller.
#
# @return A reference to a hash containing the command line settings
sub handle_commandline {
    my ($man, $help);
    my $args = {};

    # Call Getopt::Long to handle the options processing
    GetOptions('verbose|v+'     => \$args -> {"verbosity"},
               'debug|b+'       => \$args -> {"debug"},
               'coursedata|c=s' => \$args -> {"datasource"},
               'dest|d=s'       => \$args -> {"outputdir"},
               'config|f:s'     => \$args -> {"configfile"},
               'outhandler|o:s' => \$args -> {"output_handler"},
               'listhandlers|l' => \$args -> {"listhandlers"},
               'filter:s@'      => \$args -> {"filters"},    # filter can be specified once with a comma list, or many times
               'help|?|h'       => \$help,
               'man'            => \$man) or pod2usage(2);

    pod2usage(-verbose => 2) if($man);
    pod2usage(-verbose => 0) if($help);

    return $args;
}


## @fn void merge_commandline($args, $config)
# Merge the arguments into the configuration, possibly overriding settings in
# the configuration if they are specified in the arguments.
#
# @param args   A reference to a hash containing the command line arguments
# @param config A reference to the global configuration.
sub merge_commandline {
    my $args   = shift;
    my $config = shift;

    foreach my $arg (keys(%$args)) {
        $config -> {"Processor"} -> {$arg} = $args -> {$arg};
    }

    # Explicitly set the verbosity if it has not been set yet
    $config -> {"Processor"} -> {"verbosity"} = 0 if(!defined($config -> {"Processor"} -> {"verbosity"}));
}


## @fn $ load_plugins($plugindir, $list, $logger, $metadata, $template, $filter)
# Load all available plugins from the plugin directory, and either list the plugins
# or return a hashref of plugin names. 
#
# @param plugindir The directory containing the plugins to load.
# @param config    A reference to the global configuration.
# @param logger    A reference to the log support object.
# @param metadata  A reference to the metadata handler object.
# @param template  A reference to a template engine object.
# @param filter    A reference to a filter logic object.
# @return A reference to a hash containing the loaded plugins organised by type.
sub load_plugins {
    my $plugindir = shift;
    my $config    = shift;
    my $logger    = shift;
    my $metadata  = shift;
    my $template  = shift;
    my $filter    = shift;

    # Store plugins in this hashref...
    my $plugins;

    no strict 'refs'; # can't have strict refs on during plugin loading.
    my $plugin;
    while($plugin = glob(path_join($plugindir, "*.pm"))) {
        $logger -> print($logger -> DEBUG, "Detected plugin $plugin, attempting to load...");

        # load the plugin
        require $plugin; 

        # Attempt to work out what its package name is from the filename
        my ($package) = $plugin =~ m|^$path/plugins/(\w+).pm$|;

        # Obtain the handler type (should be input, output, or reference)
        my $htype = &{$package."::get_type"};
        
        $logger -> print($logger -> DEBUG, "loaded, adding '".&{$package."::get_description"}."' as $htype handler\n");
        
        # Create and store an instance of the plugin for use later.
        $plugins -> {$htype} -> {$package} -> {"obj"} = $package -> new(config   => $config, 
                                                                        logger   => $logger,  
                                                                        path     => $path, 
                                                                        metadata => $metadata,
                                                                        template => $template,
                                                                        filter   => $filter);
    }
    use strict;

    # If the user has requested a list of plugins, dump them here and exit
    if($config -> {"Processor"} -> {"listhandlers"}) {
        print "Available inputhandlers are:\n";
        foreach $plugin (sort(keys(%{$plugins -> {"input"}}))) {
            print "\t",$plugin,"\n";
        }
        print "Available outputhandlers are:\n";
        foreach $plugin (sort(keys(%{$plugins -> {"output"}}))) {
            print "\t",$plugin,"\n";
        }
        print "Available reference are:\n";
        foreach $plugin (sort(keys(%{$plugins -> {"ref"}}))) {
            print "\t",$plugin,"\n";
        }
        exit;
    }

    return $plugins;
}


## @fn $ check_input_plugins($plugins, $config, $logger)
# Run the input handler checks over the source tree, to determine which ones understand it.
# This will ask each of the input plugins to look at the tree and check whether it is in 
# a format that the plugin understands and can work on. Every plugin that can process the
# source will mark this in the plugins structure accordingly.
#
# @param plugins A reference to the hash of plugins.
# @param config  A reference to the global configuration.
# @param logger  A reference to the log support object.
# @return The number of plugins that can process the course. If none of the plugins can 
#         process the source, this function will print an error and not return.
sub check_input_plugins {
    my $plugins = shift;
    my $config  = shift;
    my $logger  = shift;

    # check which input plugins can run
    my $canrun = 0;
    foreach my $plugin (sort(keys(%{$plugins -> {"input"}}))) {
        $logger -> print($logger -> DEBUG, "Checking whether $plugin understands the source... ", 0);
        $plugins -> {"input"} -> {$plugin} -> {"use"} = $plugins -> {"input"} -> {$plugin} -> {"obj"} -> use_plugin();
        $canrun++ if($plugins -> {"input"} -> {$plugin} -> {"use"});
        $logger -> print($logger -> DEBUG, $plugins -> {"input"} -> {$plugin} -> {"use"} ? "Yes" : "No");
    }

    # if none of the input handlers understand the source, half with an error
    die "FATAL: The course data is not recognised by any of the input handlers.\nFATAL: Unable to run any plugins on the course data, giving up.\n"
        if(!$canrun);

    return $canrun;
}


## @fn void check_output_plugin($plugins, $config, $logger)
# Determine whether the selected output plugin (if one has been selected) can process the
# output of the course. This will generally always work, provided that the selected 
# output handler exists. If this function encounters any problems - no handler specified,
# the handler hasn't been created or the selected handler doesn't exist, or the handler
# can not process the course - this will exit the script with a fatal error.
#
# @param plugins A reference to the hash of plugins.
# @param config  A reference to the global configuration.
# @param logger  A reference to the log support object.
sub check_output_plugin {
    my $plugins = shift;
    my $config  = shift;
    my $logger  = shift;

    # last chance fallbacks for situations where only a single handler exists
    if(!$config -> {"Processor"} -> {"output_handler"} && scalar(keys(%{$plugins -> {"output"}})) == 1) {
        $config -> {"Processor"} -> {"output_handler"} = (keys(%{$plugins -> {"output"}}))[0];
        $logger -> print($logger -> WARNING, "OutputHander not specified, falling back on ".$config -> {"Processor"} -> {"output_handler"});
    } 
    # If we still have no output handler, give up with an error...
    setting_error("Output handler", "--outhandler") if(!$config -> {"Processor"} -> {"output_handler"});

    # check that the output handler actually exists, if not print an error and list of handlers.
    die"FATAL: The specified output handler does not exist. Please check the name and try again\n"
        if(!defined($plugins -> {"output"} -> {$config -> {"Processor"} -> {"output_handler"}} -> {"obj"}));

    # check that the output plugin could run. The handler *should* die if it can't run, but catch it anyway
    $logger -> print($logger -> DEBUG, "Checking output plugin can be run...");
    die "FATAL: The selected output plugin may not be usable on the course tree, bombing."
        if(!$plugins -> {"output"} -> {$config -> {"Processor"} -> {"output_handler"}} -> {"obj"} -> use_plugin());

}


## @fn $ load_config($configfile)
# Attempt to load the processor configuration file. This will attempt to load the
# specified configuration file, and if no filename is specified it will attempt
# to load the .courseprocessor.cfg file from the user's home directory.
#
# @param configfile Optional filename of the configuration to load. If this is not
#                   given, the configuration is loaded from the user's home directory.
# @return A reference to a configuration object, or undef if the configuration can 
#         not be loaded.
sub load_config {
    my $configfile = shift;

    # If we have no filename specified, we need to look at the user's
    # home directory for the file instead
    if(!$configfile || !-f $configfile) {
        my $home = File::HomeDir -> my_home;
        $configfile = path_join($home, ".courseprocessor.cfg");
    }

    # Get configmicro to load the configuration
    return ConfigMicro -> new($configfile) 
        if(-f $configfile);

    return undef;
}


## @fn void setting_error($arg, $param, $opt)
# Prints an error message about missing arguments and tells the user to provide them.
# 
# @param arg   The name of the setting that is missing.
# @param param The name of the command-line parameter used to set the setting.
# @param opt   Optional configuration file directive that can be used to set the setting.
sub setting_error {
    my ($arg, $param, $opt) = @_;

    print STDERR "$arg not set. Please provide a value for this setting using the $param command line argument.\n";
    print STDERR "Alternatively, set the $opt option in the configuration file.\n" if($opt);
    exit;
}


print "PEVE Course Processor version ",get_version("processor")," started.\n";

# Get logging started
my $log = new Logger();

# ------------------------------------------------------------------------------
#  Confiuration and command linehandling
#

# Sort out the command line options, if any
my $args = handle_commandline();

# Can we load any configuration?
my $config = load_config($args -> {"configfile"});

# Potentially be far more strict about this. Blarghs default to non-fatal, so this will
# just be a warning. Perhaps we should just die here.
if(!$config) {
    $log -> blargh("Unable to read configuration file");

    # If blarghs aren't fatal, we need an empty hash to work in.
    $config = { };
}

# override configuration settings with command line settings if needed
merge_commandline($args, $config);

$log -> set_verbosity($config -> {"Processor"} -> {"verbosity"});

# ------------------------------------------------------------------------------
#  Path checks
#

# Check that we have required path vriables
setting_error("Course data directory", "--coursedata") if(!$config -> {"Processor"} -> {"datasource"});
setting_error("Output directory"     , "--dest")       if(!$config -> {"Processor"} -> {"outputdir"});

# ensure the paths are really absolute
$config -> {"Processor"} -> {"datasource"} = resolve_path($config -> {"Processor"} -> {"datasource"});
$config -> {"Processor"} -> {"outputdir"}  = resolve_path($config -> {"Processor"} -> {"outputdir"});

# Dump the input/output names for reference
$log -> print($log -> DEBUG, "Using data directory  : ".$config -> {"Processor"} -> {"datasource"});
$log -> print($log -> DEBUG, "Using output directory: ".$config -> {"Processor"} -> {"outputdir"});
 
# Verify that the source dirs /are/ dirs
check_directory($config -> {"Processor"} -> {"datasource"}, "course data source directory");
check_directory($config -> {"Processor"} -> {"outputdir"} , "output directory", {"exists" => 0, "nolink" => 1, "checkdir" => 0});


# ------------------------------------------------------------------------------
#  Plugin initalisation
#

# All plugins are going to need metadata handling abilities
my $metadata = Metadata -> new("logger" => $log)
    or die "FATAL: Unable to initialise metadata engine.\n";

# And they may need to use templates. Passing lang as '' disables lang file loading
# (which we don't need here, really), and this will have no module handle specified,
# so all the template engine will do is simple translates, {L_..} and {B_[...]} will
# be passed through unaltered.
my $template = Template -> new("lang" => '', "theme" => '')
    or die "FATAL: Unable to initialise template engine.\n"; 

# Create a filter engine for use within the plugins
my $filter = Filter -> new($config -> {"Processor"} -> {"filters"})
    or die "FATAL: Unable to initialise filtering engine.\n"; 
                               
# Obtain a hashref of available plugin object handles.
my $plugins = load_plugins("$path/plugins", $config, $log, $metadata, $template, $filters);

# Determine whether the input plugins can run.
check_input_plugins($plugins, $config, $log);

# Check that the output handler is usable
check_output_plugin($plugins, $config, $log);


# ------------------------------------------------------------------------------
#  Course setup and plugin invocation
#

# remove the old output if it exists and replace it with a copy of the source
# need to use rm -rf because unlink / rmdir won't help here...
$log -> print($log -> DEBUG, "Removing old output directory.");
`rm -rf $config->{Processor}->{outputdir}`;

$log -> print($log -> DEBUG, "Copying source data.");
`cp -r $config->{Processor}->{datasource} $config->{Processor}->{outputdir}`;

# Run the input plugins that say they can be used...
foreach my $plugin (sort(keys(%{$plugins -> {"input"}}))) {
    if($plugins -> {"input"} -> {$plugin} -> {"use"}) {
        $log -> print($log -> NOTICE, "Running $plugin on the course data");
        $plugins -> {"input"} -> {$plugin} -> {"obj"} -> process();
    }
}

# Now run the output plugin. Note that the output handler is responsible
# for merging the contents of the framework directory into the output.
$log -> print($log -> NOTICE, "Running ".$config -> {"Processor"} -> {"output_handler"}." on the course data");
$plugins -> {"output"} -> {$config -> {"Processor"} -> {"output_handler"}} -> {"obj"} -> process();


$log -> print($log -> DEBUG, "Processing complete");

# This is needed to prevent circular lists blocking normal destruction
$metadata -> set_plugins(undef);

__END__

=head1 NAME

courseprocessor - convert a tree of files into a templated course

=head1 SYNOPSIS

processor [options]

 Options:
    -b, --debug             enable low-level debugging output
    -c, --coursedata=PATH   the path of the source coursedata directory.
    -d, --dest=PATH         the path to write the processed course into.
    -f, --config=FILE       an alternative configuration file to load.
    --filter=FILTER         specify filters to apply during processing.
    -h, -?, --help          brief help message.
    -l, -listhandlers       list all available input, output, and reference handlers.
    --man                   full documentation.
    -o, --outhandler        specify the output handler to process the course with.
    -v, --verbose           increase verbosity level, may be specified multiple times.


=head1 OPTIONS

=over 8

=item B<-b, --debug>

Enable debugging mode. Prevents the removal of temporary files, and enables
additional output.

item B<-c, --coursedata>

Sets the course data source directory. This argument is not optional, and the
processor will exit with an error if it is not supplied.

=item B<-d, --dest>

Specifies the name of the directory into which the course should be processed.
NOTE: if this directory exists B<it will be deleted during processing>. Take
great care to ensure that the output directory does not contain any 
pre-existing data as the processed course will completely overwrite it.

=item B<-f, --config>

Specify an alternative configuration file to use during processing. If not set,
the .courseprocessor.cfg file in the user's home directory will be used instead.

=item B<-h, -?, --help>

Print a brief help message and exits.

=item B<-l, --listhandlers>

Lists the available input, output and reference handlers and then exit.

=item B<-m, --man>

Prints the manual page and exits.

=item B<-o, --outhandler>

Overrides the outputhandler specified in the configuration file (if there is
one). Note that this must be the full name of an outputhandler loaded by 
the software and it is case sensitive. Use B<-l> to obtain the list of known
handlers for valid values.

=item B<-v, --verbose>

Increase the output verbosity. This may be repeated several times to increase
the verbosity level. -v -v -v would enable all levels of output, including debug.

=item B<--filter>

Specify one or more filters to apply during course processing. This option may be
specified multiple times if you need to apply more than one filter, or you may
provide it once with a comma separated list of filters.

=back

=head1 DESCRIPTION

=over 8

Please consult the Docs:Course_Processor documentation in the wiki for a full
description of this program.

=back

=cut
