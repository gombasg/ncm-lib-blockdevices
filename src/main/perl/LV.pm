#${PMpre} NCM::LV${PMpost}

=pod

=head1 NAME

NCM::LV

This class defines a logical volume (LV) for LVM. It is part of the
blockdevices framework.

=cut

use CAF::Process;
use NCM::Blockdevices qw ($reporter PART_FILE ANACONDA_VERSION_EL_7_0);
use NCM::VG;
use parent qw(NCM::Blockdevices);

use constant BASEPATH => "/system/blockdevices/";
use constant VGS      => "volume_groups/";
use constant LVS      => "logical_volumes/";

use constant {
    LVCACHEPOOL => '--cachepool',
    LVCACHEMODE => '--cachemode',
    LVCHUNKSIZE => '--chunksize',
    LVCONVERT  => '/usr/sbin/lvconvert',
    LVCREATE   => '/usr/sbin/lvcreate',
    LVLVS      => '/usr/sbin/lvs',
    LVSIZE     => '-L',
    LVEXTENTS  => '-l',
    LVNAME     => '-n',
    LVREMOVE   => '/usr/sbin/lvremove',
    LVRMARGS   => '-f',
    LVDISP     => '/usr/sbin/lvdisplay',
    LVSTRIPESZ => '--stripesize',
    LVSTRIPEN  => '--stripes',
    LVTYPE     => '--type',
    LVM        => 'lvm',
    LVMFORCE   => '--force',
    LVMYES     => '--yes',
    AII_LVMFORCE_PATH => '/system/aii/osinstall/ks/lvmforce',
    USEEXISTING       => '--useexisting',
};

use constant LVMWIPESIGNATURE => qw(-W y);

=pod

head2 _initialize

Where the object creation is actually done.

=cut

sub _initialize
{
    my ($self, $path, $config, %opts) = @_;

    $self->SUPER::_initialize(%opts);

    my $st = $config->getElement($path)->getTree;
    $path =~ m!/([^/]+)$!;
    $self->{devname}      = $1;
    $self->{volume_group} = NCM::VG->new(BASEPATH . VGS . $st->{volume_group}, $config);
    $self->{size}         = $st->{size};
    $self->{stripe_size}  = $st->{stripe_size} if exists $st->{stripe_size};
    $self->{chunksize}  = $st->{chunksize} if exists $st->{chunksize};
    if ($st->{cache}) {
        $self->{cache} = $st->{cache};
        $self->{cachemode} = $self->{cache}->{cachemode} if exists $self->{cache}->{cachemode};
        $self->{cache_lv} = NCM::LV->new (BASEPATH . LVS . $self->{cache}->{cache_lv}, $config);
    }
    if ($st->{devices}) {
        $self->{devices} = [];
        foreach my $devpath (@{$st->{devices}}) {
            my $dev = NCM::BlockdevFactory::build($config, $devpath, %opts);
            if (!$dev){
                $self->error("Something went wrong building device for $devpath");
                return;
            }
            push(@{$self->{devices}}, $dev);
        }
    }
    $self->{type} = $st->{type} if $st->{type};

    # Defaults to false is not defined in AII
    $self->{ks_lvmforce} = $config->elementExists(AII_LVMFORCE_PATH) ?
         $config->getElement(AII_LVMFORCE_PATH)->getValue : 0;

    return $self;
}

=pod

=head2 new_from_system

Creates a logical volume object from its path on the disk. The device
won't be in the convenient /dev/VG/LV form which is just a symbolik
link, but rather, on the actual /dev/entry, which is
/dev/mapper/VG-LV. This method converts the names to something the
rest of the class can understand.

=cut

sub new_from_system
{
    my ($class, $dev, $cfg, %opts) = @_;

    $dev =~ m{(/dev/.*[^-]+)-([^-].*)$};
    my ($vgname, $devname) = ($1, $2);
    $devname =~ s/-{2}/-/g;
    my $vg = NCM::VG->new_from_system($vgname, $cfg, %opts);
    my $self = {
        devname      => $devname,
        volume_group => $vg,
        log => ($opts{log} || $reporter),
    };
    return bless($self, $class);
}

=pod

=head2 _gen_convert_command


Returns cache lv convert command

=cut

sub _gen_convert_command
{
    my $self = shift;
    my @opts;
    if ($self->{cachemode}){
        @opts = (LVCACHEMODE, $self->{cachemode});
    }
    my $command = [LVCONVERT, '-y', LVTYPE, 'cache', @opts, LVCACHEPOOL,
                   "$self->{volume_group}->{devname}/$self->{cache_lv}->{devname}",
                   "$self->{volume_group}->{devname}/$self->{devname}"];
    return $command;
}


=pod

=head2 lvcache_ks

Print the ks code for the cache on the logical volume.

=cut

sub lvcache_ks
{
    my $self = shift;
    $self->{cache_lv}->create_ks;
    my $command = join(" ", @{$self->_gen_convert_command()});

    print <<EOC
    lvm lvs $self->{volume_group}->{devname}/$self->{devname} | awk '{ print \$5 }' | grep $self->{cache_lv}->{devname} > /dev/null
    if [ "\$?" -ne 0 ]
    then
        $command
    fi
EOC

}

=pod

=head2 create_cache

Creates the cache on the logical volume. Returns $? (0 if
success). If the logical volume cache already exists, it returns 0 without
doing anything.

Returns 0 on success.

=cut

sub create_cache
{
    my $self = shift;
    my $ec = $self->{cache_lv}->create;
    if ($ec != 0) {
        return $?;
    }
    my $output = CAF::Process->new([LVLVS, "$self->{volume_group}->{devname}/$self->{devname}"], log => $self)->output();
    my @lines = split(/\n/, $output);
    if ($lines[1] && $lines[1] =~ /\s\[$self->{cache_lv}->{devname}\]\s/){
        $self->debug(5, "Cache $self->{cache_lv}->{devname} on logical volume $self->devpath already exists. Leaving");
        return 0;
    }
    my $command = $self->_gen_convert_command();
    CAF::Process->new($command, log => $self)->execute();
    if ($?) {
        $self->error("Failed to make cache $self->{cache_lv}->{devname} on $self->{devname}");
    }
    return $?;
}

=pod

=head2 create

Creates the logical volume on the system. Returns $? (0 if
success). If the logical volume already exists, it returns 0 without
doing anything.

Returns 0 on success.

=cut

sub create
{
    my $self = shift;

    return 1 if (!$self->is_valid_device);

    my ($szflag, $sz);

    if ($self->devexists) {
        if ($self->{cache}) {
            return $self->create_cache();
        } else {
            $self->debug(5, "Logical volume ", $self->devpath, " already exists. Leaving");
            return 0;
        }
    }
    $self->{volume_group}->create == 0 or return $?;
    if ($self->{size}) {
        $szflag = LVSIZE;
        $sz     = $self->{size};
    } else {
        $szflag = LVEXTENTS;
        $sz     = $self->{volume_group}->free_extents;
    }
    my @stopt = ();
    if (exists $self->{stripe_size}) {
        @stopt =
            (LVSTRIPESZ, $self->{stripe_size}, LVSTRIPEN,
            scalar(@{$self->{volume_group}->{device_list}})
            );
    }
    my @devices = ();
    if ($self->{devices}){
        foreach my $dev (@{$self->{devices}}) {
            push (@devices, $dev->devpath);
        }
    }

    my @type_opts = ();
    if ($self->{type}) {
        @type_opts = (LVTYPE, $self->{type});
    }
    my @chunk_opts = ();
    if ($self->{chunksize}) {
        @chunk_opts = (LVCHUNKSIZE, $self->{chunksize});
    }
    my $command = [LVCREATE, @type_opts, @chunk_opts, $szflag, $sz, LVNAME, $self->{devname},
                   $self->{volume_group}->{devname}, @stopt, @devices];

    CAF::Process->new($command, log => $self)->execute();
    if ($?) {
        $self->error("Failed to create logical volume", $self->devpath);
        return $?;
    }
    if ($self->{cache}) {
        return $self->create_cache();
    }
    return 0;

}

=pod

=head2 remove

Removes the logical volume from the system.

Returns 0 on success.

=cut

sub remove
{
    my $self = shift;

    return 1 if (!$self->is_valid_device);

    if ($self->devexists) {
        CAF::Process->new([LVREMOVE, LVRMARGS, $self->{volume_group}->devpath . "/$self->{devname}"], log => $self)->execute();
        if ($?) {
            $self->error("Failed to remove logical volume ", $self->devpath);
            return $?;
        }
    }

    # TODO: why not return with exitcode from this call?
    $self->{volume_group}->remove;
    return 0;
}

=pod

=head2 devexists

Returns true if the device already exists in the system.

=cut

sub devexists
{
    my $self = shift;
    CAF::Process->new([LVDISP, "$self->{volume_group}->{devname}/$self->{devname}"], log => $self)->execute();
    return !$?;
}

=pod

=head2 devpath

Returns the absolute path to the block device file.

=cut

sub devpath
{
    my $self = shift;
    return $self->{volume_group}->devpath . "/" . $self->{devname};
}

=pod

=head1 Methods exposed to AII

=head2 should_print_ks

Returns whether the logical volume should be defined in the
Kickstart. This is, whether the volume group holding the logical
volume should be printed.

=cut

sub should_print_ks
{
    my $self = shift;
    return $self->{volume_group}->should_print_ks;
}

=pod

=head2 should_create_ks

Returns whether the logical volume should be defined in the
%pre script.

=cut

sub should_create_ks
{
    my $self = shift;
    return $self->{volume_group}->should_create_ks;
}

=pod

=head2 ksfsformat

Given a filesystem instance C<fs>, return the kickstart formatting command
to be used in the kickstart commands section.

=cut

sub ksfsformat
{
    my ($self, $fs) = @_;

    my @format = $self->SUPER::ksfsformat($fs);

    if ($self->{anaconda_version} >= ANACONDA_VERSION_EL_7_0) {
        push @format, USEEXISTING;

        if (exists $fs->{label}) {
            push @format, "--label", '"' . $fs->{label} . '"';
        }
    }

    # The useexisting_lv can be set by AII in ks.pm
    # TODO: Remove once aii-ks passes anaconda_version
    if ($fs->{useexisting_lv}) {
        $self->debug(5, 'useexisting flag enabled');
        push @format, USEEXISTING;
    }

    return @format;
}


=head2 print_ks

If the logical volume must be printed, it prints the appropriate
kickstart commands.

=cut

sub print_ks
{
    my ($self, $fs) = @_;

    return unless $self->should_print_ks;

    $self->{volume_group}->print_ks;
    print "\n";

    print join(" ",
               "logvol", $fs->{mountpoint},
               "--vgname=$self->{volume_group}->{devname}",
               "--name=$self->{devname}",
               $self->ksfsformat($fs),
               "\n");
}

=pod

=head2 del_pre_ks

Generates teh Bash code for removing the logical volume from the
system, if that's needed.

=cut

sub del_pre_ks
{
    my $self = shift;

    $self->ks_is_valid_device;

    my $devpath = $self->{volume_group}->devpath . "/$self->{devname}";

    my $force = $self->{ks_lvmforce} ? LVMFORCE : '';

    print <<EOF;
wipe_metadata $devpath 1
lvm lvremove $force $devpath
EOF

    $self->{volume_group}->del_pre_ks;
}

sub create_ks
{
    my $self = shift;
    my $path = $self->devpath;

    return unless $self->should_create_ks;

    $self->ks_is_valid_device;

    my @stopts = ();
    if (exists $self->{stripe_size}) {
        @stopts =
            (LVSTRIPESZ, $self->{stripe_size}, LVSTRIPEN,
            scalar(@{$self->{volume_group}->{device_list}})
            );
    }

    my @devices = ();
    if ($self->{devices}){
        foreach my $dev (@{$self->{devices}}) {
            push (@devices, $dev->devpath);
        }
    }

    my @type_opts = ();
    if ($self->{type}) {
        @type_opts = (LVTYPE, $self->{type});
    }
    my @chunk_opts = ();
    if ($self->{chunksize}) {
        @chunk_opts = (LVCHUNKSIZE, $self->{chunksize});
    }


    print <<EOC;
if ! lvm lvdisplay $self->{volume_group}->{devname}/$self->{devname} > /dev/null
then
EOC

    $self->{volume_group}->create_ks;
    print <<EOF;
    sed -i '\\:@{[$self->{volume_group}->devpath]}\$:d' @{[PART_FILE]}
EOF
    my $size = '-l 99%FREE';
    $size = "-L $self->{size}M"
        if (exists($self->{size})
        && defined($self->{size})
        && "$self->{size}" =~ m/\d+/);

    # 'Option --wipesignatures is unsupported with cache pools.'
    my @wipe_ops = ();
    if ($self->{ks_lvmforce} && (!$self->{type} || $self->{type} ne 'cache-pool')) {
        push(@wipe_ops, LVMWIPESIGNATURE);
        if ($self->{anaconda_version} >= ANACONDA_VERSION_EL_7_0) {
            # On RH7, "lvcreate -W y" would still stop waiting for confirmation
            push(@wipe_ops, LVMYES);
        }
    }

    print <<EOC;

    lvm lvcreate @wipe_ops -n $self->{devname} \\
        @type_opts \\
        $self->{volume_group}->{devname} \\
        $size \\
        @chunk_opts \\
        @stopts \\
        @devices
        echo @{[$self->devpath]} >> @{[PART_FILE]}

EOC
    if ($self->{cache}) {
        $self->lvcache_ks();
    }
    print "fi\n";
}

1;
