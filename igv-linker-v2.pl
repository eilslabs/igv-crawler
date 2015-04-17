#!/usr/bin/env perl
use strict;
use warnings;
#
# This script scans the specified project folder for
# folders containing <samplename>.bam + <samplename>.bai
# All such bam+bai-files will be linked in the specified output dir
# Additionally it will make a .html index page for users to browse.
#

use File::Find;
use File::Path;
use File::Spec::Functions;
use HTML::Template;
use Getopt::Long;
use Data::Dumper;


#####################################################################################
# CONSTANTS
#

# the local FS dir where apache looks for stuff to host
#   script will create subdirs in it named 'lc $project_name'
my $host_base_dir = "/public-otp-files/";

# the externally visible URL for 'host_base_dir' (NO TRAILING SLASH!)
my $www_base_url  = "https://otpfiles.dkfz.de";

# subdir name where to store symlinks for both file-system and URL
my $link_dir = "links";

# END CONSTANTS #####################################################################


#####################################################################################
# COMMAND LINE PARAMETERS
#
# defaults to demo-settings
my $project_name = 'demo';
my @scan_dirs;
my $pid_regex;
#####################################################################################


# global list to keep track of all the bam+bai files we have found
# format:
# {
#   'patientId1' => [ '/some/file/path.bam', 'some/file/path.bai', ...],
#   'patientId2' => [ '/other/file/path.bam', 'some/other/path.bai', ...],
# }
#
# Sadly must be global, otherwise the File::find findFilter can't add to it
my %bambai_file_index = ();




main();




#####################################################################################
# FUNCTION DEFINITIONS
#


sub parseArgs {
  GetOptions ('project=s'   => \$project_name, # will be used as "the $project_name project", as well as (lowercased) subdir name
              'scandir=s'   => \@scan_dirs,    # where to look for IGV-relevant files
              'pidformat=s' => \$pid_regex     # the regex used to extract the patient_id from a file path.
             )
  or die("Error parsing command line arguments");

  # sanity check: project name?
  die 'No project name specified, aborting!' if ($project_name eq '');

  # sanity check: pid-format
  die "Didn't specifify pid-format, cannot extract patient ID from file paths, aborting!" if ($pid_regex eq "");

  # canonicalize + sanity check @scandirs
  #
  # scandirs may be entered by either:
  # 1) repeated command line args:          "--scandir /dir/a --scandir /dir/b"
  #    --> multiple entries in @scan_dirs
  # 2) single command line arg with commas: "--scandir /dir/a,/dir/b"
  #    --> split all strings
  @scan_dirs = split(',', join(',', @scan_dirs));
  die 'Specified no directories to scan, aborting!' if ((scalar @scan_dirs) == 0);
  
  my $project_name_lower = lc $project_name;
  my $output_file_path   = catfile( $host_base_dir, $project_name_lower, "$project_name_lower.html");
  my $link_dir_path      = catdir ( $host_base_dir, $project_name_lower, $link_dir);
  my $link_dir_url       = $www_base_url . "/" . $project_name_lower . "/" . $link_dir; # trailing slash is added in __DATA__ template

  return ($link_dir_path, $link_dir_url, $output_file_path)
}


sub main {
  my ($link_dir_path, $link_dir_url, $output_file_path) = parseArgs();

  print "Started IGV scanner+linker for project '$project_name'\n";

  print "looking for IGV-relevant files in:\n";
  foreach my $dir (@scan_dirs) {
    print "  $dir\n";
  }
  # finddepth->findFilter stores into global %bambai_file_index, via sub addToIndex()
  finddepth(\&findFilter, @scan_dirs);

  clearOldLinksIn($link_dir_path);

  # make desired LSDF files accessible from www-directory
  makeAllFileSystemLinks($link_dir_path, %bambai_file_index);

  makeHtmlPage($output_file_path, $link_dir_url, $project_name, %bambai_file_index);
}


sub findFilter {
  my $filename = $File::Find::name;
  return if -d $filename;                     # skip directories
  return unless $filename =~ /(.*)\.ba[im]$/; # skip files that're not a bamfile or a bam-index

  addToIndex($filename);
}


sub addToIndex {
  my $file = shift;

  # extract the patient ID from the identifier
  my $patientId = derivePatientIdFrom($file);
  if ($patientId ne 'ERROR-NO-MATCH') {
    # append the file-path to our list of files-per-patient
    $bambai_file_index{$patientId} = [] unless $bambai_file_index{$patientId};
    push @{ $bambai_file_index{$patientId} }, $file;
  }
}


# Function to derive a patientID from a filename
sub derivePatientIdFrom {
  my $filepath = shift;
  if ($filepath =~ /$pid_regex/) {
    my $patientId = $1;
    return $patientId;
  } else {
    return 'ERROR-NO-MATCH';
  }
}


# recursively clears all links from a directory, and then all empty dirs.
# This should normally clear a link-dir made by this script, but nothing else.
# sanity-checks the provided directory to match /public-otp-files/*/links, to avoid "find -delete" mishaps
sub clearOldLinksIn {
  my $dir_to_clear = shift;

  print "Clearing out links and empty directories in $dir_to_clear\n";

  # sanity, don't let this work on directories that aren't ours
  die "paramaters specify invalid directory to clear: $dir_to_clear" unless $dir_to_clear =~ /^\/public-otp-files\/.*\/links/; # intentionally hardcoding 'links' instead of $link_dir

  # delete all symlinks in our directory
  system( "find -P $dir_to_clear -mount -depth -type l  -delete" );
  # clear out all directories that are now empty (or contain only empty directories -> '-p')
  system( "find -P $dir_to_clear -mount -depth -type d  -exec rmdir -p {} + 2> /dev/null" );
}


sub makeAllFileSystemLinks {
  my $link_target_dir = shift;
  my %files_per_patientId = @_;

  print "creating links in $link_target_dir\n";

  foreach my $patientId (keys %files_per_patientId) {
    my $newDir = makeDirectoryFor($link_target_dir, $patientId);
    foreach my $originalFile (@{ $files_per_patientId{$patientId} }) {
      my $filename = getFileNameFor($originalFile);

      my $newPath = catfile($newDir, $filename);
      symlink $originalFile, $newPath;
    }
  }
}


sub makeDirectoryFor {
  my $link_target_dir = shift;
  my $patientId = shift;

  my $path = catfile($link_target_dir, $patientId);
  mkpath($path) unless -d $path;

  return $path;
}


sub getFileNameFor {
  my $filepath = shift;
  my ($volume, $dir, $filename) = File::Spec->splitpath($filepath);
  return $filename;
}


sub makeHtmlPage {
  my $output_file = shift;
  my $file_host_dir = shift;
  my $project_name = shift;
  my %files_per_patientId = @_;

  # Get the HTML template
  my $html = do { local $/; <DATA> };
  my $template = HTML::Template->new(
    scalarref         => \$html,
    global_vars       => 1 # needed to make outer-var file_host_dir visible inside per-patient loops for links
  );


  # remove clutter: clear out the index files so they won't be explicitly listed in the HTML
  # IGV will figure out the index-links itself from the corresponding non-index filename
  my %nonIndexFiles = findDatafilesToDisplay(%bambai_file_index);

  my $formatted_patients = formatPatientDataForTemplate(%nonIndexFiles);
  my $formatted_scandirs = [ map {{dir => $_}} @scan_dirs ];
  # for some reason, writing 'localtime' directly in the param()-map didn't work, so we need a temp-var
  my $timestamp = localtime;

  # insert everything into the template
  $template->param(
    project_name  => $project_name,
    timestamp     => $timestamp,
    file_host_dir => $file_host_dir,
    patients      => $formatted_patients,
    scandirs      => $formatted_scandirs
  );


  writeContentsToFile($template->output(), $output_file);
}


# Finds all datafiles that should be listed in the html
#
# namely:
# - .bam's having .bai's
# - .bam's having .bam.bai's
#
# the index-files themselves (.bai's, .bam.bai's) are not included in the html-output
# because by this point, the symlinks already exist, and IGV will derive
# the index-file-link from the data-file-link
sub findDatafilesToDisplay {
  my %original = @_;
  my %filtered = ();

  foreach my $patientId (keys %original) {
    ### meaningful temp names
    my @all_files = sort @{ $original{ $patientId }};

    my @bams_having_bais    = findFilesWithIndices('.bam', '.bai',     @all_files);
    my @bams_having_bambais = findFilesWithIndices('.bam', '.bam.bai', @all_files);

    # store result
    @{ $filtered{ $patientId } } = sort (@bams_having_bais, @bams_having_bambais);
  }

  return %filtered;
}

# returns a list of the datafiles that have a matching index-file
#
# i.e. given a list of found datafiles+indexfiles
# returns the list of datafiles that have an indexfile in the input
# effectively removing both indexless-datafiles AND the indexfiles from the input
sub findFilesWithIndices {
  # meaningful temp names
  my $data_extension = shift; # e.g. .bam
  my $data_pattern = quotemeta($data_extension) . '$';
  my $index_extension = shift; # e.g .bai or .bam.bai
  my $index_pattern = quotemeta($index_extension) . '$';
  my @all_files = @_;

  # first, gather up our datafiles and indexfiles
  my @found_data    = grep { $_ =~ /$data_pattern/  } @all_files;
  my @found_indices = grep { $_ =~ /$index_pattern/ } @all_files;

  # second, map each datafile to its _expected_ indexfile
  my %expected_indices = map {
    my $found_data = $_;

    my $expected_index = $found_data;
    $expected_index =~ s/$data_pattern/$index_extension/;

    # 'return' map k,v pair
    # NOTE: key,value swapped in counterintuitive way for cleverness below
    { $expected_index => $found_data}
  } @found_data;

  # finally: be clever :-)
  # delete the found index-files from expected-index-files map;
  #   since "delete ASSOC_ARRAY" returns the associated values of all deleted keys
  #   (i.e. the datafile attached to each found-index-file, thanks to the 'inverted' key,value from before)
  #   this immediately gives us a list of all datafiles which have a corresponding indexfiles
  my @data_having_index = delete @expected_indices{@found_indices};
  # %expected_indices now contains the hash { missing-index-file => found-data-file }

  # remove undefs resulting from leftover index-files whose data-file was removed/not-found
  # (removing non-existant keys returns an undef)
  @data_having_index = grep { defined } @data_having_index;

  return @data_having_index;
}


# prepares patient datastructure to insert into template
#
# it creates the nested structure for the list-of-patients-with-list-of-their-files
# formatted as a (nested) list-of-maps, for HTML::Template
# [
#  {
#    patient_id => "patient_1",
#    linked_files => [
#      { filename => "file1" },
#      { filename => "file2" },
#      ...
#    ]
#  },
# ...]
#
sub formatPatientDataForTemplate {
  my %files_per_pid = @_;

  # sorry for the next unreadable part!
  return [
    # outer 'list' of patient + linked-files
    map {{
        patient_id => $_ ,

        # inner 'list' of filenames
        linked_files => [
          map {{ filename => getFileNameFor($_) }} @{$files_per_pid{$_}}
        ]

    }} sort keys %files_per_pid
  ];
}


sub writeContentsToFile {
  my $contents = shift;
  my $filename = shift;

  print "writing contents to $filename\n";
  open (FILE, "> $filename") || die "problem opening $filename\n";
  print FILE $contents;
  close (FILE);
}

# END FUNCTION DEFINITIONS ########################################################

###################################################################################
# Data section: the HTML::Template to be filled in by the code
__DATA__
<html>
<head>
  <title>IGV files for <!-- TMPL_VAR NAME=project_name --></title>
</head>
<body style="padding-right: 280px;">

<h1><!-- TMPL_VAR NAME=project_name --> IGV linker</h1>

<p>
  The IGV-relevant files for the <!-- TMPL_VAR NAME=project_name --> project have been made available online here over a secured connection.<br/>
  Below are some clickable links that will add said files into a running IGV session.<br/>
  Learn more about this functionality at the IGV-website under <a target="blank" href="https://www.broadinstitute.org/software/igv/ControlIGV">controlling IGV</a>
</p>

<p>
  <strong>NOTE! the links below only work if</strong>
  <ol>
    <li>IGV is already running</li>
    <li>you enabled port-control (in view > preferences > advanced > enable port > port 60151)</li>
    <li>you have the correct reference genome loaded before clicking the link.<br/>
      (do this before loading files, or all positions will show up as mutated)<br/>
      to add missing genomes to IGV, see menu > genomes > load genome from server<br/>
  </ol>
</p>

<p id="about-blurb"><small>
  IGV-linker v2.0, a service by the eilslabs data management group<br/>
  questions, wishes, improvements or suggestions: <a href="mailto:j.kerssemakers@dkfz-heidelberg.de">j.kerssemakers@dkfz-heidelberg.de</a><br/>
  powered by <a href="http://threepanelsoul.com/2013/12/16/on-perl/">readable perl&trade;</a><br/>
  last updated: <!-- TMPL_VAR NAME=timestamp --><br/>
  generated from files found in:
  <ul>
  <!-- TMPL_LOOP NAME=scandirs -->
    <li><!-- TMPL_VAR NAME=dir --></li><!-- /TMPL_LOOP -->
  </ul>
</small></p>

<!-- SIDE BAR MENU: has quick-links to each patient-id header below -->
<div id="menu" style="
  position: fixed; top: 5px; right: 0px;
  font-size: small;
  height: 95%;
  overflow-y: auto;
  overflow-x: hidden;
  padding: 4px 20px 4px 6px;
  background-color: white;
  border: 1px solid black;
  border-right: none;
  border-bottom-left-radius: 7px;
  border-top-left-radius: 7px;
  white-space: nowrap;
">
Jump to:
<ul style="padding-left: 26px;">
<!-- TMPL_LOOP NAME=patients -->
<li><a href="#<!-- TMPL_VAR NAME=patient_id -->"><!-- TMPL_VAR NAME=patient_id --></a></li><!-- /TMPL_LOOP -->
</ul>
</div>

<h1>Patient Information</h1>
<!-- TMPL_LOOP NAME=patients -->
  <h2 id="<!-- TMPL_VAR NAME=patient_id -->"><!-- TMPL_VAR NAME=patient_id --></h2>
  <ul>
    <!-- TMPL_LOOP NAME=linked_files -->
      <li><a href="http://localhost:60151/load?file=<!-- TMPL_VAR NAME=file_host_dir -->/<!-- TMPL_VAR NAME=patient_id -->/<!-- TMPL_VAR NAME=filename -->">
          <!-- TMPL_VAR NAME=filename -->
      </a></li><!-- /TMPL_LOOP -->
  </ul><!-- /TMPL_LOOP -->

</body>
</html>
