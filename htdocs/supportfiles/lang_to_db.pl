#!/usr/bin/perl -w

use strict;
use lib "/var/www/webperl";

use DBI;
use Webperl::ConfigMicro;
use Webperl::Utils qw(path_join superchomp);

## @fn $ clear_language_table($dbh, $tablename)
# Clear the contents of the specified language table. This truncates the table,
# erasing all its contents, and resetting the autoincrement for the ID.
#
# @param dbh       The database handle to issue queries through.
# @param tablename The name of the database table containing the language variables.
# @return undef on success, otherwise an error message.
sub clear_language_table {
    my $dbh       = shift;
    my $tablename = shift;

    my $nukeh = $dbh -> prepare("TRUNCATE `$tablename`");
    $nukeh -> execute()
        or return "Unable to clear language table: ".$dbh -> errstr;

    return undef;
}


## @fn $ set_language_variable($dbh, $tablename, $name, $lang, $message)
# Set the langauge variable with the specified name and lang to contain
# the specified message. This will determine whether the name has already
# been set in the specified language, and if so the message will not be
# updated, and an error will be returned.
#
# @param dbh       The database handle to issue queries through.
# @param tablename The name of the database table containing the language variables.
# @param name      The name of the language variable.
# @param lang      The language the variable is being defined in.
# @param message   The message to set for the language variable.
# @return undef on success, otherwise an error message.
sub set_language_variable {
    my ($dbh, $tablename, $name, $lang, $message) = @_;

    # First check that the variable hasn't already been defined
    my $checkh = $dbh -> prepare("SELECT message FROM `$tablename` WHERE `name` LIKE ? AND `lang` LIKE ?");
    $checkh -> execute($name, $lang)
        or return "Unable to perform language variable check: ".$dbh -> errstr;

    my $row = $checkh -> fetchrow_arrayref();
    return "Redefinition of language variable $name in language $lang (old: '".$row -> [0]."', new: '$message')"
        if($row);

    # Doesn't exist, make it...
    my $newh = $dbh -> prepare("INSERT INTO `$tablename` (`name`, `lang`, `message`)
                                VALUES(?, ?, ?)");
    my $rows = $newh -> execute($name, $lang, $message);
    return "Unable to perform language variable insert: ". $dbh -> errstr if(!$rows);
    return "User insert failed, no rows added." if($rows eq "0E0");

    return undef;
}


## @fn $ load_language($dbh, $tablename, $langdir)
# Load all of the language files in the appropriate language directory into the
# database. This will attempt to load all .lang files inside the langdir/lang/
# directory, and store the language variables defined therein in the database.
# The database language table is cleared before adding new entries.
#
# @return true if the language files loaded correctly, undef otherwise.
sub load_language {
    my $dbh       = shift;
    my $tablename = shift;
    my $langdir   = shift;

    my $res = clear_language_table($dbh, $tablename);
    return $res if($res);

    print "Processing language directories in '$langdir'...\n";

    opendir(LANGDIR, $langdir)
        or return "Unable to open languages directory '$langdir' for reading: $!";

    my @langs = readdir(LANGDIR);
    closedir(LANGDIR);

    foreach my $lang (@langs) {
        next if($lang =~ /^\.+$/);

        my $langsubdir = path_join($langdir, $lang);
        next unless(-d $langsubdir);

        print "Checking for lang files in '$lang'...\n";

        # open it, so we can process files therein
        opendir(LANG, $langsubdir)
            or return "Unable to open language directory '$langsubdir' for reading: $!";

        my @files = readdir(LANG);
        closedir(LANG);

        foreach my $name (@files) {
            # Skip anything that doesn't identify itself as a .lang file
            next unless($name =~ /\.lang$/);

            print "Processing language file '$name'...\n";

            my $filename = path_join($langsubdir, $name);

            # Attempt to open and parse the lang file
            if(open(WORDFILE, "<:utf8", $filename)) {
                my @lines = <WORDFILE>;
                close(WORDFILE);

                foreach my $line (@lines) {
                    superchomp($line);

                    # skip comments
                    next if($line =~ /^\s*#/);

                    # Pull out the key and value, and
                    my ($key, $value) = $line =~ /^\s*(\w+)\s*=\s*(.*)$/;
                    next unless(defined($key) && defined($value));

                    # Unslash any \"s
                    $value =~ s/\\\"/\"/go;

                    print "Storing language variable '$key'\n";
                    $res = set_language_variable($dbh, $tablename, $key, $lang, $value);
                    return $res if($res);
                }
            }  else {
                return "Unable to open language file $filename: $!";
            }
        } # foreach $name (@files) {
    } # foreach my $lang (@langs) {

    return undef;
}


my $settings = Webperl::ConfigMicro -> new("../config/site.cfg")
    or die "Unable to open configuration file: ".$Webperl::SystemModule::errstr."\n";

die "No 'language' table defined in configuration, unable to proceed.\n"
    unless($settings -> {"database"} -> {"language"});

my $dbh = DBI->connect($settings -> {"database"} -> {"database"},
                       $settings -> {"database"} -> {"username"},
                       $settings -> {"database"} -> {"password"},
                       { RaiseError => 0, AutoCommit => 1, mysql_enable_utf8 => 1 })
    or die "Unable to connect to database: ".$DBI::errstr."\n";

my $error = load_language($dbh, $settings -> {"database"} -> {"language"}, "../lang")
    or print "Finished successfully.\n";

print "Failed: $error\n" if($error);
