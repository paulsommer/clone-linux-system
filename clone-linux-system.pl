#!/usr/bin/env perl
# coding: utf8

# Script zum clonen einer Linux system-partition auf eine andere

use strict;
use File::Basename;
use File::Basename;
use Cwd;
use Term::ANSIColor qw(:constants);
$Term::ANSIColor::AUTORESET = 1;

my $program_dir = Cwd::abs_path($0);
$program_dir =~ s#(.*)/.+#$1#;

if ( $> != 0 ) {
	print "\n", RED BOLD "Dieses Programm muss als root ausgeführt werden.\n"; 
	exit (0);
}



my $realRun=0;

my $source_in = $ARGV[0];
my $target_in = $ARGV[1];

my $sourceSystem = $ARGV[2];

if (!$source_in || !$target_in) {
	usage();
	exit;
}

my $answer;

#--------------------------------------------------------
sub usage {
	# See info about colors here: /usr/share/perl/5.18.2/Term/ANSIColor.pm
	my $me = basename($0);

	print BOLD "NAME\n";
	print "\t$me - Übertrage ein Linux-System auf eine andere Festplatte\n";
	print BOLD "USAGE\n";
	print	"\t$me <Quelle> <Ziel>\n\n";

	print BOLD "Dieses Script versucht, eine Linux-Installation auf eine andere Festplatte zu übertragen.\n"; 
	print      "Die Zielplatte muss bereits passend partitioniert sein mit mindestens einer Partition für das \n";
	print      "System, einer Swap-Partition und ggf. weitere Partitionen wie 'home', 'var' oder 'boot'.\n";
	print      "\n";
	print RED BOLD "Bereits existiernde Daten auf der Festplatte werden komplett überschrieben.\n";
	print      "Das Script kann nur eine oberflächliche Prüfung der Gegebenheiten vornehmen.\n";
	print      "Letztendlich ist der Anwender (also Du! verantwortlich für die Ergebnisse.\n";
	print      "Eine vorherige Daten- und Systemsicherung ist auf jeden Fall notwendig.\n";
	print      "Eine Fehlbedienung oder ein Programmfehler kann das System komplett zerstören.\n";
	print      "\n";
	print RED BOLD "Sei also gewarnt und lies die Ausgaben des Scripts genau, bevor Du irgendwo '", BOLD BLACK "j", RED BOLD "' drückst\n";
	print      "\n";
	print BOLD "Aufruf des Scripts:\n";
	print      "\n";
	print      "clone-linux-system <Quelle> <Ziel>\n";
	print      "\n";
	print      "Als Quelle und als Ziel müssen die Devicenamen der jeweiligen Festplatte angegeben angegeben werden (z.B. '/dev/sda /dev/sdb')\n";
	print      "Das Script fragt dann die einzelnen Partitionen ab, die kopiert werden sollen.\n";
	print      "\n";
	print      "Das Ziel wird komplett überschrieben. Existierende Dateien werden gelöscht.\n";
	print      "Die Daten werden 1:1 von der Quelle übernommen (einige temporäre und cache Dateien ausgenommen).\n";
	print      "Anschließend werden die Partitions-IDs im Bootmanager und in /etc/fstab an die IDs der neuen Platte angpasst.\n";
	print      "\n";
	print      "Am Ende wird nach einer Sicherheitsabfrage der Bootloader auf der Zielplatte installiert.\n";
	print      "\n";
	print      "\n";
	print      "\n";
	print      "\n";
}


unless (-b $source_in) {
  print RED BOLD "Quelldevice '$source_in' existiert nicht.\n";
	exit;
}

unless (-b $target_in) {
  print RED BOLD "Zieldevice '$target_in' existiert nicht.\n";
	exit;
}

####################################################
# Get the partition information for the source drive
my $sourceDiskInfo = `sfdisk -u M -l $source_in 2>/dev/null`;  # use -u S for sectors, B for blocks C for cylinders
if ($?) {
  print RED BOLD "Kann die Partitionsinfo der Quellplatte '$source_in' nicht bekommen.\n";
	exit;
}
my @sPartitions;
my $pNr=0;
foreach (split /\n/, $sourceDiskInfo) {
	# ignore all lines that doesn't contain partition infos
	if (m#(/dev/\S+[1-9][0-9]*)\s*(\*?)\s*(\S+)\s*(\S+)\s*(\S+)\s*(\S+)\s*(\S+)\s*(.+)#) {
		# print "Gerät:$1, boot:$2, Anf:$3, Ende:$4, MiB:$5, #Blöcke:$6, Id:$7, System:$8, \n";
		$pNr++;
		my $p = $1;
		next if ($5 == 0 || $p =~ m#/dev/sd.4#);
		$sPartitions[$pNr]->{dev} = $1;		  # Initialize the cration of a new hash element in the partition array
		my $pi = $sPartitions[$pNr];
		$pi->{is_mounted} = 0;
		$pi->{boot} = $2;		
		$pi->{size} = $5;		
		$pi->{id} = $6;		
		$pi->{type} = $7;		
		$pi->{sys} = $8;		
		# Size human readable
		$pi->{size} =~ s/[+-]$//;
		$pi->{size_h} = reverse $pi->{size};
		$pi->{size_h} =~ s/(\d\d\d)(?=\d)(?!\d*\.)/$1./g;
		$pi->{size_h} = reverse ($pi->{size_h}) . " MB";
		$pi->{mountpoint} = "/tmp$pi->{dev}";

		my $blkInfo = `blkid $pi->{dev}`;
		if ($blkInfo eq '') {
      # This is (hopefully) the extended partition
			$pi->{fstype} = 'extended';
    } else {
			if ($blkInfo =~ /UUID="([^"]+).*TYPE="([^"]+)/) {
				$pi->{uuid} = $1;
				$pi->{fstype} = $2;
			}
    }
		
		# Is this partition currently mounted?
		my $mount = `mount|grep $pi->{dev}`;
		if ($mount =~ / on (\S+)/) {
			$pi->{mountpoint} = $1;
			$pi->{is_mounted} = 1;
			$pi->{was_mounted} = 1;
	  }
	}
}

print BOLD "\nPartitionen auf dem Quellaufwerk:\n";
print BOLD "   Gerät   boot     Größe     Typ \n";
for (my $spNr = 1; $spNr < @sPartitions; $spNr++) {
	next unless defined $sPartitions[$spNr];
	my $pi =  $sPartitions[$spNr];
	printf "%10s %1s  %14.12s  %s\n", $pi->{dev}, $pi->{boot}, $pi->{size_h}, $pi->{sys};
}

my $targetDiskInfo = `sfdisk -u M -l $target_in 2>/dev/null`;  # use -u S for sectors, B for blocks C for cylinders
if ($?) {
  print RED BOLD "Kann die Partitionsinfo der Zielplatte '$target_in' nicht bekommen.\n";
	exit;
}
my @tPartitions;
$pNr = 0;
foreach (split /\n/, $targetDiskInfo) {
	# ignore all lines that doesn't contain partition infos
	if (m#(/dev/\S+[1-9][0-9]*)\s*(\*?)\s*(\S+)\s*(\S+)\s*(\S+)\s*(\S+)\s*(\S+)\s*(.+)#) {
		# print "Gerät:$1, boot:$2, Anf:$3, Ende:$4, MiB:$5, #Blöcke:$6, Id:$7, System:$8, \n";
		$pNr++;
		my $p = $1;
		next if ($5 == 0 || $p =~ m#/dev/sd.4#);
		$tPartitions[$pNr]->{dev} = $1;		  # Initialize the cration of a new hash element in the partition array
		my $pi = $tPartitions[$pNr];
		$pi->{is_mounted} = 0;
		$pi->{boot} = $2;		
		$pi->{size} = $5;		
		$pi->{id} = $6;		
		$pi->{type} = $7;		
		$pi->{sys} = $8;
		# Size human readable
		$pi->{size} =~ s/[+-]$//;
		$pi->{size_h} = reverse $pi->{size};
		$pi->{size_h} =~ s/(\d\d\d)(?=\d)(?!\d*\.)/$1./g;
		$pi->{size_h} = reverse ($pi->{size_h}) . " MB";
		$pi->{mountpoint} = "/tmp$pi->{dev}";

		my $blkInfo = `blkid $pi->{dev}`;
		if ($blkInfo eq '') {
      # This is (hopefully) the extended partition
			$pi->{fstype} = 'extended';
    } else {
			if ($blkInfo =~ /UUID="([^"]+).*TYPE="([^"]+)/) {
				$pi->{uuid} = $1;
				$pi->{fstype} = $2;
			}
    }
    
		# Is this partition currently mounted?
		my $mount = `mount|grep $pi->{dev}`;
		if ($mount =~ / on (\S+)/) {
			$pi->{mountpoint} = $1;
			$pi->{is_mounted} = 1;
			$pi->{was_mounted} = 1;
	  }
	}
}


#############################################################################
# Ask which of the partitions on the source drive is the system partition

my $spSystem;
if ($sourceSystem > 0) {
	$spSystem = $sourceSystem;
} else {

	print "\n";
	my $spSystem;
	do {
		print "Welche dieser Partition enthält das System? ", BOLD "Bitte nur die Nummer eingeben: ", RESET;
		$spSystem = <STDIN>;		# source partition with system
		chomp $spSystem;
	} until ($spSystem > 0);
}
print "\n\n";

my $sSystemDir;

#############################################################################
# Try to get file system information from the source drive from the /etc/fstab of the source drive
my $pi = $sPartitions[$spSystem];
my $mp;
if (!$pi->{is_mounted}) {
	# Mount the source Parttion and read in the fstab
	do_mount($pi);
}
	
# Read the fstab from the source system
my $fstab;
{
	local $/ = undef;
	open FILE, $pi->{mountpoint} . "/etc/fstab" or print "Kann Datei '$pi->{mountpoint}/etc/fstab' nicht öffnen\n";
	binmode FILE;
	$fstab = <FILE>;
	close FILE;
}

for (my $p = 1; $p < @sPartitions; $p++) {
	my $uuid = $sPartitions[$p]->{uuid} ;
	my $dev = $sPartitions[$p]->{dev};
	next unless $uuid;
	if ($fstab =~ m#^UUID=$uuid\s+(/\S*) #m) {
		$sPartitions[$p]->{originalMp} = $1;
  } elsif ($fstab =~ m#$dev\s+(/\S*) #m) {
		$sPartitions[$p]->{originalMp} = $1;
	}  
	my $a=0;
}
		

######################################################################################################
# try to correlate the partitions (find the partitions with the smallest difference in size (in percent))
# For each partition on the source device try to find the best fitting partition on the target device
for (my $partNr = 1; $partNr < @sPartitions; $partNr++) {
	next unless defined $sPartitions[$partNr];
	my $partInfo = $sPartitions[$partNr];
	next unless defined $partInfo->{fstype};  # 	Don't choke on empty entries
	if ($partInfo->{fstype} =~ /swap/i || $partInfo->{fstype} =~ /extended/i) {
		$partInfo->{tpCandidate} = 0;
		# Dont show swap and extended in the selection
		next;
	}
	$partInfo->{tpDiff} = 100;
	for (my $tpNr = 1; $tpNr < @tPartitions; $tpNr++) {
		next unless defined $tPartitions[$tpNr];
		if ($partInfo->{fstype} =~ /swap/i || $partInfo->{fstype} =~ /extended/i) {
			# Dont compare with swap and extended partitions
			next;
		}
		my $diff = abs( ($partInfo->{size} - $tPartitions[$tpNr]{size}) / $partInfo->{size});
		# Give some advantage to devices that where mounted on the source system
		if ($partInfo->{originalMp}) {
      $diff *= 0.5;
    }
		if ($diff < $partInfo->{tpDiff}) {
      $partInfo->{tpDiff} = $diff;
      $partInfo->{tpCandidate} = $tpNr;
    }
	}
	
}

# Now remove duplicate target candidates by keeping only the one with the best fit (smallest tpDiff)
for (my $partNr = 1; $partNr < @sPartitions; $partNr++) {
	next unless $sPartitions[$partNr]->{tpCandidate};
	for (my $partNrTest = $partNr+1; $partNrTest < @sPartitions; $partNrTest++) {
		next unless $sPartitions[$partNr]->{tpCandidate} eq $sPartitions[$partNrTest]->{tpCandidate};
		if ($sPartitions[$partNr]->{tpDiff} <= $sPartitions[$partNrTest]->{tpDiff}) {
			$sPartitions[$partNrTest]->{tpCandidate} = 0;
		} elsif ($sPartitions[$partNr]->{tpDiff} > $sPartitions[$partNrTest]->{tpDiff}) {
			$sPartitions[$partNr]->{tpCandidate} = 0;
			last;
		}
	}
}


####################################################################
# Display the source and target device and the assumed correlations
my @colors=(RESET,ON_BRIGHT_RED, ON_BRIGHT_GREEN, ON_BLUE, ON_BRIGHT_BLUE, ON_BRIGHT_MAGENTA, ON_BRIGHT_MAGENTA, ON_BRIGHT_CYAN, ON_BRIGHT_YELLOW, ON_BRIGHT_BLACK,, ON_GREEN, ON_CYAN, ON_RED, ON_MAGENTA);

print BOLD "\nQuellgerät:\n";
print BOLD "     Gerät   boot     Größe     Typ         Mount Point\n";
for (my $spNr = 1; $spNr < @sPartitions; $spNr++) {
	next unless defined $sPartitions[$spNr];
	my $pInfo =  $sPartitions[$spNr];
	if (! defined $pInfo->{fstype} || $pInfo->{fstype} =~ /swap/i || $pInfo->{fstype} =~ /extended/i) {
		# Dont show swap and extended in the selection
		next;
	}
	printf "%1s  %1s%10s %1s  %14.12s  %-10.10s  %s\n", $colors[$spNr], RESET, $pInfo->{dev}, $pInfo->{boot}, $pInfo->{size_h}, $pInfo->{sys}, $pInfo->{originalMp};
}

print BOLD "\nZielgerät:\n";
print BOLD "     Gerät   boot     Größe     Typ    \n";
for (my $tpNr = 1; $tpNr < @tPartitions; $tpNr++) {
	next unless defined $tPartitions[$tpNr];
	my $pInfo =  $tPartitions[$tpNr];
	if ($pInfo->{fstype} =~ /swap/i || $pInfo->{fstype} =~ /extended/i) {
		# Don't show swap and extended in the selection
		next;
	}
	# look for the corrosponding source partition
	my $sourcePartition = 0;
	for (my $i = 1; $i < @sPartitions; $i++) {
		if ($sPartitions[$i]->{tpCandidate} == $tpNr) {
      $sourcePartition = $i;
			last;
    }
	}
	printf "%1s  %1s%10s %1s  %14.12s  %.10s\n", $colors[$sourcePartition], RESET , $pInfo->{dev}, $pInfo->{boot}, $pInfo->{size_h}, $pInfo->{sys};
}

print "\nGleiche Farben im Quell- und Zielaufwerk kennzeichnen Zuordnungsvorschläge.\n\n";
print "Für jede Partition des Quellaufwerks wird jetzt abgefragt, auf welche Partition im Ziellaufwerk sie kopiert werden soll.\n";
print "Soll eine Partition nicht übernommen werden, kann ", BOLD "0", RESET " für diese eingegeben werden.\n";
print "Mit ", BOLD "Enter", RESET " wird der Vorschlag in der eckigen Klammer [1] übernommen.\n\n";

for (my $i = 1; $i < @sPartitions; $i++) {
	next unless defined $sPartitions[$i];
	my $sp = $sPartitions[$i];
	##my $a = length($sp);
	next if (! defined $sp->{fstype} || $sp->{fstype} =~ /swap/i || $sp->{fstype} =~ /extend/i);
	my $mountPoint = $sp->{originalMp} || '';
	$mountPoint = "swap" if ($sp->{sys} =~ /swap/i);
	# Delete the target partition candidates from the sPartition table for non mounted Partitions
	# The candidates will be used in the suggestion in the next step and when doing the real work
	###$sp->{tpCandidate} = 0 unless ($mountPoint gt '');
  my $tpNr = $sp->{tpCandidate};
		
	$answer = $tpNr;
	print "Zielpartition für ", $colors[$i], "  ", RESET, BOLD $sp->{dev}, RESET ", (", BOLD sprintf ("%-11s", $mountPoint), RESET ") angeben: [", BOLD "$answer", RESET "]: ";
	$answer = <STDIN>;		# source partition with system
	chomp $answer;
	if ($answer eq '') {
		$sp->{tpNr} = $tpNr; 		# Use the suggestion
	} else {
		$sp->{tpNr} = $answer;
	}
}

# Output the summary

print BOLD "\nZusammenfassung:\n";
print "Die folgende Partitionen werden kopiert:\n";

for (my $i = 1; $i < @sPartitions; $i++) {
	#next unless defined $sPartitions[$i];
	next unless defined $sPartitions[$i];
	my $sp = $sPartitions[$i];
	next unless ($sp->{tpCandidate} > 0);
	my $tp = $tPartitions[$sp->{tpCandidate}];
	my $mp = $sp->{mountpoint};

	###$mp = "Swap" if ($sp->{sys} =~ /swap/i);
#	print BOLD, $sp->{dev}, RESET " -> ", BOLD, $tp->{dev}, RESET " - Mounts: ", BOLD, $sp->{mountpoint}, RESET " -> ", BOLD, $tp->{mountpoint}, RESET "\n";
	print BOLD, $sp->{dev}, RESET " -> ", BOLD, $tp->{dev}, RESET " - Mounts: ", BOLD, sprintf ("%-13s", $sp->{mountpoint}) , RESET " -> ", BOLD, $tp->{mountpoint}, RESET "\n";


}


print "\n";
print BRIGHT_WHITE ON_RED BOLD "*** Der Kopiervorgang startet nach der nächsten Bestätigung. ***";
print RESET "\nDer Vorgang wird nur gestartet wenn ", BOLD "JA", RESET " eingegeben wird. Ctrl-C bricht das Script ab.\n\n";

do {
	print "Sollen die oben genannten Aktionen jetzt durchgeführt werden? ";
	$answer = <STDIN>;		# source partition with system
	chomp $answer;
} until ($answer eq "JA");

#print "\n";




for (my $partNo = 1; $partNo < @sPartitions; $partNo++) {
	next unless defined $sPartitions[$partNo];
	my $sp = $sPartitions[$partNo];
	next if $sp->{sys} =~ /swap/i;
	next unless $sp->{tpCandidate} > 0;
	my $tp = $tPartitions[$sp->{tpCandidate}];
	
	# check if source partition is mounted and mount it
	my $smp = ''; 		# source partition mount point
	my $mountInfo = `df | grep $sp->{dev}`;
		print "___________________________________________________________________________\n\n";
	if ($mountInfo =~ /\s(\S+)$/) {
    $smp = $1;
		print "Quelle ", BOLD $sp->{dev}, RESET " ist gemountet unter  ", BOLD "$smp\n";
  } else {
		$smp = "/tmp$sp->{dev}";
		print "Quelle ", BOLD, $sp->{dev}, RESET " wird gemountet unter ", BOLD "$smp\n";
		`mkdir -p $smp`;
		`mount -o ro $sp->{dev} $smp`;
	}
	
	# check if target partition is mounted and mount it
	my $tmp = ''; 		# target partition mount point
	$mountInfo = `df | grep $tp->{dev};`;
	if ($mountInfo =~ /\s(\S+)$/) {
    $tmp = $1;
		print "Ziel   ", BOLD $tp->{dev}, RESET " ist gemountet unter  ", BOLD "$tmp\n";
  } else {
		$tmp = "/tmp$tp->{dev}";
		print "Ziel   ", BOLD, $tp->{dev}, RESET " wird gemountet unter ", BOLD "$tmp\n";
		`mkdir -p $tmp`;
		`mount $tp->{dev} $tmp`;
	}
	
	print BOLD " Kopiere Daten von '$smp' nach '$tp->{dev}'.", RESET " Das kann lange dauern...\n";

	if ($partNo == $spSystem) {
		# Dies ist die Systempartition. mit einigen Sonderbehandlungen
		`rm -fr $tmp/tmp $tmp/var/tmp $tmp/var/backups $tmp/var/cache`;
		`mkdir -p $tmp/tmp $tmp/var/tmp $tmp/var/backups $tmp/var/cache`;
		`chmod -R 1777 $tmp/tmp $tmp/var/tmp $tmp/var/backups $tmp/var/cache`;
	}
	my $cmd;
	my $rsyncVer = `rsync --version`;
	$rsyncVer =~ s/.*version ([0-9]+\.[0-9]+)/$1/;		# extract the first two verdion numbers from the info output. This can be treates as a floa
	if ($rsyncVer >= 3.1) {
		$cmd = "rsync -ax --delete --force --no-inc-recursive --info=progress2 --exclude-from=$program_dir/clone-excludes.lst $smp/ $tmp";
  } else {
		$cmd = "rsync -ax --delete --force --info=stats --exclude-from=$program_dir/clone-excludes.lst $smp/ $tmp";
	}
  
	print "Befehl: $cmd \n";
		
	#		my $a = `rsync  -axv --delete --force  --exclude-from=$program_dir/clone-excludes.lst $smp $tmp`;
	###system("rsync  -ax --delete --force  --exclude-from=$program_dir/clone-excludes.lst $smp $tmp");
	system($cmd);
	print BOLD " Kopieren beendet\n\n";
	
	if ($partNo == $spSystem) {
		# Dies ist die Systempartition. mit einigen Sonderbehandlungen
		#############
		# adapt fstab
		{
			local $/ = undef;
			print BOLD "Passe /etc/fstab an...\n";
			open FILE, $tp->{mountpoint} . "/etc/fstab" or print RED BOLD "Kann Datei '$tp->{mountpoint}/etc/fstab' nicht öffnen\n";
			binmode FILE;
			my $fstab = <FILE>;
			close FILE;
			
			# Change the uuids for mounted partitions and swap
			for (my $pn = 1; $pn < @sPartitions; $pn++) {
				my $partInfo = $sPartitions[$pn];
				my $oldUuid = $sPartitions[$pn]->{uuid};
				next unless $oldUuid;
				my $newUuid = $tPartitions[$sPartitions[$pn]->{tpCandidate}]->{uuid};
				print "Changing UUID for $tPartitions[$sPartitions[$pn]->{tpCandidate}]->{dev} from $oldUuid to $newUuid\n";
				$fstab =~ s#$oldUuid#$newUuid#g;
			}
			# which partition is the swap on the new device?
			my $swapUuid;
			for (my $pn = 1; $pn < @tPartitions; $pn++) {
				if ($tPartitions[$pn]->{fstype} =~ /swap/i) {
					$swapUuid = $tPartitions[$pn]->{uuid};
					last;
        }
			}
			print "Changing UUID for swap to $swapUuid\n";
			$fstab =~ s#^(UUID=)[\S](\s+.*swap.*)#$1$swapUuid$2#ig;
			
			open FILE, ">$tp->{mountpoint}/etc/fstab" or print RED BOLD "Kann Datei '$tp->{mountpoint}/etc/fstab' nicht zum Schreiben öffnen\n";
			print FILE $fstab;
			close FILE;
		
			###################
			# adapt grub config
			print "\n", BOLD "Passe /boot/grub/grub.config an...\n";
			open FILE, "$tp->{mountpoint}/boot/grub/grub.cfg" or print RED BOLD "Kann Datei '$tp->{mountpoint}/boot/grub/grub.cfg' nicht öffnen\n";
			binmode FILE;
			my $grubcfg = <FILE>;
			close FILE;
			
			# Change the uuid for the system partition
			my $partInfo = $sPartitions[$partNo];
			my $oldUuid = $partInfo->{uuid};
			my $newUuid = $tPartitions[$partInfo->{tpCandidate}]->{uuid};
			print "Changing UUID for system partition to $newUuid in grub.cfg\n";
			$grubcfg =~ s#$oldUuid#$newUuid#g;

			open FILE, ">$tp->{mountpoint}/boot/grub/grub.cfg" or print RED BOLD "Kann Datei '$tp->{mountpoint}/boot/grub/grub.cfg' nicht zum Schreiben öffnen\n";
			print FILE $grubcfg;
			close FILE;
			
			####################
			# Install bootloader
			print "\n", BOLD "Installiere Bootloader...\n";
			my $diskDev = $tp->{dev};
			$diskDev =~ s/(.*?)[0-9]+/$1/;
			$cmd = "grub-install --boot-directory $tp->{mountpoint}/boot $diskDev";
			print "Befehl: $cmd \n\n";
			`$cmd`;
			#print "\n";
		}
	}		
		

	`umount $sp->{dev}` unless ($sp->{was_mounted});
	`umount $tp->{dev}` unless ($tp->{was_mounted});

}

#--------------------------------------------------------------------------------------------------
sub do_mount {
	my $pi = pop;
	exit 1 if ($pi->{is_mounted});

	print "Prüfe mount status von $pi->{dev}\n";

	unless ($pi->{mountpoint} gt '') {
    # Create a generig mount directory in /tmp/<device_name>
		$pi->{mountpoint} = "/tmp$pi->{dev}";
		
		print "Erzeuge Verzeichnis $pi->{mountpoint}\n";
		my $res = `mkdir -p $pi->{mountpoint}`;
		$res = `mount $pi->{dev} $pi->{mountpoint}`;
  }
	
	# Test if mount was successful

print "doing mount | grep ".$pi->{dev}."\n";

	`mount|grep $pi->{dev}`;
	if ($? == 0) {
		$pi->{is_mounted} = 1;
	} else {
		# Something has gone wrong
		print BRIGHT_RED "Kann '$pi->{dev}' nicht in Verzeichnis '$pi->{mountpoint}' mounten.\n";
		die "Abbruch!";
	}

}
