#!/usr/bin/perl -w

####
# extension to am-wxPOE
# PD Sebastian, 4.20.13

####
# absolutely minimal wxPOE sample
# Ed Heil, 5/5/05

use strict;
use warnings;
use SubDir::ProcessManager;
use SubDir::StateManager;
use SubDir::DataManager;
use SubDir::wxPOE_HeilApp;
use Wx;

use YAML::XS qw(LoadFile DumpFile Load Dump);
use DateTime;

use POE;
use POE::Loop::Wx;
use POE::Session;

use Socket;
use POE qw(Wheel::SocketFactory
  Wheel::ReadWrite
  Driver::SysRW
  Filter::Reference
);
use POE::Component::Client::TCP;
use POE qw(Component::Server::TCP);
use POE::Filter::JSON;

####
# base script contains the following steps
# 1) open initial/primary config file and retrieve am-wxPOE environment parameters
#    - bootstrap initial environment as needed
# 2) create process mgr - $_pmgr
#    - $_pmgr holds routines to control shared application processes; in and outside of Wx
# 3) create state mgr $_smgr
#    - $_smgr holds routines to manage the state of server, such as response to signals and external events
# 4) create data mgr $_dmgr
#    - $_dmgr provides for data channel management. Useful for the monitoring of the integration of multiple data streams.
# 5) bootstrap $_*mgrs* - create pre-POE operating environment (keeps simple things simple - no
#    need to manage non-serial event behavior)
# 6) run am-wxPOE
# 7) pass-in $_*mgrs* at POE session _start state

my $pre_alpha_version = 0.002;
my $publish_date = '2013.04.19';
my $my_server_address = "127.0.0.1";
my $my_server_port = 5505;
my $my_server_type = "WxPOE";
my $carp = 1;

## basic signal variables
my $_signal = {};
my $_signal_latch = {};
my $_init_signal = 0;
my $_shutdown = 0; ## indicator that close any open POE client sessions
my $_shutdown_triggered = 0; ## latch to prevent duplicate calls to shutdown function
my $sd_check_count = 0;
my $sd_client_checks = 0;
my $clients_to_check = 0;
my $mgr_count = 0;
my $signal_done = 0;

## declare globals to run timer for server kill
my $k_count = 0;
my $kill_session = 0;
my $kill_ct_delay = 3;

######
## Open primary server configuration file and set initial parameters
######
my $config_dir = "conf/";
my $config_file = "config_" . $my_server_type . ".yml";
my $file = $config_dir . $config_file;
my $sconfig = {}; ## keyed hash of configuration parameters
if(open(my $fh, '<', $file)) {
	$sconfig = LoadFile $file;
} else {
	print "== Info: no config file [$file] exists\n";
}

######
## Create $_*mgrs*
######
my $_pmgr = ProcessManager->new();
my $_smgr = StateManager->new();
my $_dmgr = DataManager->new();

######
## Set initial operating state
######
my $params = {};
$params->{AppName} = 'Sebastian-Heil App';
$_pmgr->init($params);
$_smgr->init($params);


########################################
## PACKAGES (meant to be separate files)
########################################

####### File /SubDir/HeilApp/wxPOEFrame.pm
package wxPOEFrame;
#######################################
#
#######################################
use strict;
use warnings;

use Wx;

use vars qw(@ISA);
@ISA = qw(Wx::Frame);
use base 'Wx::Frame';

use Wx( :everything
);

use Wx::Event qw(EVT_SIZE
                 EVT_MENU
                 EVT_IDLE
                 EVT_COMBOBOX
                 EVT_UPDATE_UI
                 EVT_TOOL_ENTER
				 EVT_BUTTON
				 EVT_CLOSE
				 EVT_TIMER
				 );

my $frame_designation = 'control'; 
my $show_pulse = 1;

#### expected variables...
my $display_obj = undef;
my $_pmgr = undef;
my $_smgr = undef;
my $_dmgr = undef;

my $shutdown_signal = 0;
my $_signal_ptr = {};
my $_signal_key_latch = {};
my $_signal_object_hold = {};


sub new {
    my $class = shift;
	my $node = undef;
	if(@_) { $node = shift; }

    my $winframe  = $class->SUPER::new( undef, -1, 'Server Monitor', [0,0], wxDefaultSize, );
    push @MonitorApp::frames, $winframe;    # stow in main for poe session to use

    return $winframe;
}
sub init_wframe {
    my $winframe = shift;
	$_pmgr = shift;
	$_smgr = shift;
	$_dmgr = shift;
	
	## Create a new Display object
	my $display = wxPOEDisplay->new( $winframe, $_pmgr, $_smgr, $_dmgr );

	## store display object handle
	$winframe->_display_handle($display);
	
	## start and setup display
#	$display->set_wx_gui_settings($_smgr);
	$display->start_display($winframe);

	return;
}
sub _display_handle {
	my $self = shift;
	if(@_) { $display_obj = shift; }
	return $display_obj;
}
sub _pmgr_handle {
	my $self = shift;
	if(@_) { $_pmgr = shift; }
	return $_pmgr;
}
sub _smgr_handle {
	my $self = shift;
	if(@_) { $_smgr = shift; }
	return $_smgr;
}
sub frameIdent {
	return $frame_designation;
}
sub signalPtr {
	if($_[1]) {
		## store pointer to signal href initialized in outer POE/Wx loop
		$_signal_ptr = $_[1];
	}
	return $_signal_ptr;
}
sub checkForSignal {
	if(defined($_[1])) {
		if(defined($_[2])) {
			if(!exists $_signal_key_latch->{$_[1]}) {
				$_signal_ptr->{$_[1]} = $_[2];
				$_signal_key_latch->{$_[1]} = $_[2];
			}
		}
		return $_signal_ptr->{$_[1]};
	}
	return $_signal_ptr;
}
sub checkSignalLatch {
	if(defined($_[1])) {
		if(exists $_signal_key_latch->{$_[1]}) {
			return 1;
		}
		return 0;
	}
	return undef;
}
sub clearSignal {
	if(defined($_[1])) {
		if(exists $_signal_ptr->{$_[1]}) {
			delete $_signal_ptr->{$_[1]};
		}
		if(exists $_signal_key_latch->{$_[1]}) {
			delete $_signal_key_latch->{$_[1]};
		}
		return 1;
	}
	return undef;
}
sub tempSignalObject {
	if(defined($_[1])) {
		if(defined($_[2])) {
			if(!$_[2]) {
				if(exists $_signal_object_hold->{$_[1]}) {
					delete $_signal_object_hold->{$_[1]};
				}
				return undef;
			}
			$_signal_object_hold->{$_[1]} = $_[1];
		}
		return $_signal_object_hold->{$_[1]};
	}
	return $_signal_object_hold;
}
sub CheckForShutdownSig {
	if($_[1]) {
		$shutdown_signal = $_[1];
	}
	return $shutdown_signal;
}
sub PoeEvent    { 
	if($show_poe_event) {
		my $display = $_[0]->_display_handle();
		my $txt = "POE Event.";
		if($display) { ## POE event could occur before winframe is initiated
			$display->append_textbox($poe_event_post_box,$txt);
		}
	}
}
sub PulseEvent    { 
	my $text = $_[1];
	if($show_pulse) {
		my $display = $_[0]->_display_handle();
		my $txt = "Pulse Event.";
		if($display) { ## Pulse event could occur before winframe is initiated
			$display->append_textbox($pulse_event_post_box,$txt);
		}
	}
	$_[0]->displayUpdate();
	return 1;
}
sub passThruSignalResponse {
	if(defined($_[1])) {
		my $sig = $_[0]->checkForSignal();
		if(!scalar(keys %$sig)) { print "\nERROR! Signal mismatch for [".$_[1]."] pass thru\n\n"; }
		if($_[1]=~/__some_signal_key__/i) {
			if(!exists $sig->{$_[1]}) { 
				print "\nERROR! Signal KEY mismatch for [".$_[1]."] pass thru\n\n"; 
				return;
			}
			if($sig->{$_[1]}==__?SOME_VALUE?__) {
				my $status = 0;
				if(defined($_[2])) {
					$status = $_[2];
				}
				if($status) {
					my $btn_obj = $_[0]->tempSignalObject(__some_signal_key__);
					my $btn_label_swap = 'New State';
					$btn_obj->SetLabel($btn_label_swap);
					$_[0]->tempSignalObject(__some_signal_key__,0); ## clear temp button object holding
				}
				return;
			}
		}
	}
}
sub OnClose {
    my ( $self, $event ) = @_;

    # make sure the POE session doesn't try to send events
    # to a nonexistent widget!
    @MonitorApp::frames = grep { $_ != $self } @MonitorApp::frames;
    $self->Destroy();
}
sub OnShutdown {
    my ( $self, $event ) = @_;

	## be gracefully and shutdown servers started...
	my $display = $self->_display_handle();
	$display->status_message("Shutting down system...Please wait!");

	## signal servers to shutdown
	$self->CheckForShutdownSig(1);
}
sub MakeWxShutdown {
	my $winframe = $_[0];
    # make sure the POE session doesn't try to send events
    # to a nonexistent widget!
	@MonitorApp::frames = grep { $_ != $winframe } @MonitorApp::frames;
	$winframe->Destroy();
}
sub ButtonEvent { $_[0]->{text}->AppendText("Button Event.\n"); }

1;

####### File /SubDir/HeilApp/wxPOEFrame2.pm
package wxPOEFrame2;
#######################################
#
#######################################
use strict;
use warnings;

use Wx;

use vars qw(@ISA);
@ISA = qw(Wx::Frame);
use base 'Wx::Frame';
use Wx(
    qw [wxDefaultPosition wxDefaultSize wxVERTICAL wxFIXED_MINSIZE
      wxEXPAND wxALL wxTE_MULTILINE ]
);
use Wx::Event qw(EVT_BUTTON EVT_CLOSE);

my $frame_designation = 'h2frame'; 
my $show_pulse = 1;

#### expected variables...
my $display_obj = undef;
my $_pmgr = undef;
my $_smgr = undef;
my $_dmgr = undef;

my $_signal_ptr = {};
my $_signal_key_latch = {};
my $_signal_object_hold = {};


sub new {
    my $class = shift;
	my $node = undef;
	if(@_) { $node = shift; }

    my $winframe  = $class->SUPER::new( undef, -1, 'Server Monitor', [0,0], wxDefaultSize, );
    push @MonitorApp::frames, $winframe;    # stow in main for poe session to use

    return $winframe;
}
sub init_wframe {
    my $winframe = shift;
	$_pmgr = shift;
	$_smgr = shift;
	$_dmgr = shift;
	
	## Create a new Display object
	my $display = wxPOEDisplay2->new( $winframe, $_pmgr, $_smgr, $_dmgr );

	## store display object handle
	$winframe->_display_handle($display);
	
	## start and setup display
#	$display->set_wx_gui_settings($_smgr);
	$display->start_display($winframe);

	return;
}
sub _display_handle {
	my $self = shift;
	if(@_) { $display_obj = shift; }
	return $display_obj;
}
sub _pmgr_handle {
	my $self = shift;
	if(@_) { $_pmgr = shift; }
	return $_pmgr;
}
sub _smgr_handle {
	my $self = shift;
	if(@_) { $_smgr = shift; }
	return $_smgr;
}
sub frameIdent {
	return $frame_designation;
}
sub signalPtr {
	if($_[1]) {
		## store pointer to signal href initialized in outer POE/Wx loop
		$_signal_ptr = $_[1];
	}
	return $_signal_ptr;
}
sub checkForSignal {
	if(defined($_[1])) {
		if(defined($_[2])) {
			if(!exists $_signal_key_latch->{$_[1]}) {
				$_signal_ptr->{$_[1]} = $_[2];
				$_signal_key_latch->{$_[1]} = $_[2];
			}
		}
		return $_signal_ptr->{$_[1]};
	}
	return $_signal_ptr;
}
sub checkSignalLatch {
	if(defined($_[1])) {
		if(exists $_signal_key_latch->{$_[1]}) {
			return 1;
		}
		return 0;
	}
	return undef;
}
sub clearSignal {
	if(defined($_[1])) {
		if(exists $_signal_ptr->{$_[1]}) {
			delete $_signal_ptr->{$_[1]};
		}
		if(exists $_signal_key_latch->{$_[1]}) {
			delete $_signal_key_latch->{$_[1]};
		}
		return 1;
	}
	return undef;
}
sub tempSignalObject {
	if(defined($_[1])) {
		if(defined($_[2])) {
			if(!$_[2]) {
				if(exists $_signal_object_hold->{$_[1]}) {
					delete $_signal_object_hold->{$_[1]};
				}
				return undef;
			}
			$_signal_object_hold->{$_[1]} = $_[1];
		}
		return $_signal_object_hold->{$_[1]};
	}
	return $_signal_object_hold;
}
sub PoeEvent    { 
	if($show_poe_event) {
		my $display = $_[0]->_display_handle();
		my $txt = "POE Event.";
		if($display) { ## POE event could occur before winframe is initiated
			$display->append_textbox($poe_event_post_box,$txt);
		}
	}
}
sub PulseEvent    { 
	my $text = $_[1];
	if($show_pulse) {
		my $display = $_[0]->_display_handle();
		my $txt = "Pulse Event.";
		if($display) { ## Pulse event could occur before winframe is initiated
			$display->append_textbox($pulse_event_post_box,$txt);
		}
	}
	$_[0]->displayUpdate();
	return 1;
}
sub passThruSignalResponse {
	if(defined($_[1])) {
		my $sig = $_[0]->checkForSignal();
		if(!scalar(keys %$sig)) { print "\nERROR! Signal mismatch for [".$_[1]."] pass thru\n\n"; }
		if($_[1]=~/__some_signal_key__/i) {
			if(!exists $sig->{$_[1]}) { 
				print "\nERROR! Signal KEY mismatch for [".$_[1]."] pass thru\n\n"; 
				return;
			}
			if($sig->{$_[1]}==__?SOME_VALUE?__) {
				my $status = 0;
				if(defined($_[2])) {
					$status = $_[2];
				}
				if($status) {
					my $btn_obj = $_[0]->tempSignalObject(__some_signal_key__);
					my $btn_label_swap = 'New State';
					$btn_obj->SetLabel($btn_label_swap);
					$_[0]->tempSignalObject(__some_signal_key__,0); ## clear temp button object holding
				}
				return;
			}
		}
	}
}
sub OnClose {
    my ( $self, $event ) = @_;

    # make sure the POE session doesn't try to send events
    # to a nonexistent widget!
    @MonitorApp::frames = grep { $_ != $self } @MonitorApp::frames;
    $self->Destroy();
}
sub OnShutdown {
    my ( $self, $event ) = @_;

	## be gracefully and shutdown servers started...
	my $display = $self->_display_handle();
	$display->status_message("Shutting down system...Please wait!");

	## signal servers to shutdown
	$self->CheckForShutdownSig(1);
}
sub MakeWxShutdown {
	my $winframe = $_[0];
    # make sure the POE session doesn't try to send events
    # to a nonexistent widget!
	@MonitorApp::frames = grep { $_ != $winframe } @MonitorApp::frames;
	$winframe->Destroy();
}

1;

####### File /SubDir/HeilApp/wxPOEDisplay.pm
package wxPOEDisplay;
#######################################
#
#######################################
use strict;
use warnings;

use vars qw(@ISA);
use Wx::Grid;
@ISA = qw(Wx::Frame);
use Wx qw(:everything);
@ISA = qw(Wx::Grid);

use Wx::Event qw(EVT_SIZE
                 EVT_MENU
                 EVT_IDLE
                 EVT_COMBOBOX
                 EVT_UPDATE_UI
                 EVT_TOOL_ENTER
				 EVT_BUTTON
				 EVT_LEFT_DCLICK
				 EVT_RIGHT_DOWN
				 EVT_CLOSE
				 EVT_GRID_CELL_CHANGED
				 EVT_TEXT_ENTER
);

sub new {
	my $proto = shift;
	my $class = ref($proto) || $proto;
	my $self  = {};
	$self->{NAME}     = undef;
	$self->{START_SECS}     = 0;
	$self->{WX_GUI_CONFIG_FILE} = 'GuiConfigure.yml';
	$self->{CONFIG_DIR} = 'conf/';
	$self->{DISPLAY_SETTINGS} = {};
	$self->{WX_GUI_SETTINGS} = {};
	$self->{WX_GUI_PANELS_AREF} = [];
	$self->{WX_GUI_GRIDS_AREF} = [];
	$self->{WX_GUI_GRID_PANEL_MAP} = {};
	$self->{ACTIVE_TEXT_BOXES} = {'righttextbox'=>1,'lefttextbox'=>1};
	$self->{ACTIVE_STATIC_TEXT} = {'status_text'=>1};
	$self->{INPUT_BOX_FIELD} = {};
	$self->{DISPLAY_WINDOW} = undef;
	$self->{PMGR_OBJECT} = undef;
	$self->{SMGR_OBJECT} = undef;
	$self->{DMGR_OBJECT} = undef;
	bless ($self, $class);

	my $window = shift;
	$self->_window_handle($window);										
	my $mgr = shift;
	$self->_pmgr_handle($mgr);
	$mgr = shift;
	$self->_smgr_handle($mgr);
	$mgr = shift;
	$self->_dmgr_handle($mgr);

	return $self;
}
sub _window_handle {
	my $self = shift;
	if(@_) { $self->{DISPLAY_WINDOW} = shift; }
	return $self->{DISPLAY_WINDOW};
}
sub _pmgr_handle {
	my $self = shift;
	if(@_) { $self->{PMGR_OBJECT} = shift; }
	return $self->{PMGR_OBJECT};
}
sub _smgr_handle {
	my $self = shift;
	if(@_) { $self->{SMGR_OBJECT} = shift; }
	return $self->{SMGR_OBJECT};
}
sub _dmgr_handle {
	my $self = shift;
	if(@_) { $self->{DMGR_OBJECT} = shift; }
	return $self->{DMGR_OBJECT};
}
sub wx_gui_config_file {
	my $self = shift;
	if(@_) { $self->{WX_GUI_CONFIG_FILE} = shift; }
	return $self->{WX_GUI_CONFIG_FILE};
}
sub set_wx_gui_settings {
	my $self = shift;
	
	my $_display_config_file = $self->{TS_CONFIG_DIR} . $self->wx_gui_config_file();
	my $s = $_pmgr->ts_load_file($_display_config_file);

	if(!exists $s->{display_config}) {
		print "\nERROR! Cannot set monitor display config settings! [$s] appears corrupt\n\n";
		exit;
	}
	my $d = $s->{display_config};
	if(exists $d->{panel_list}) {
		$self->_gui_panels($d->{panel_list});
	}
	if(exists $d->{grid_to_panel_map}) {
		$self->_grids_to_panels($d->{grid_to_panel_map});
	}
	$self->_set_gui_grids($d);
	$self->_wx_gui_settings($d);
	return 1;
}
sub _wx_gui_settings {
	my $self = shift;
	if(@_) { 
		$self->{WX_GUI_SETTINGS} = shift;
	}
	return $self->{WX_GUI_SETTINGS};
}
sub _set_gui_grids {
	my $self = shift;
	my $d = shift;
	my $gds = $self->_gui_grids();
	foreach my $gd (@$gds) {
		if(exists $d->{$gd}) {
			my $g_conf = $d->{$gd};
			## configure grids
		}
	}
	return 1;
}
sub _gui_panels {
	my $self = shift;
	my $p = $self->{WX_GUI_PANELS_AREF};
	if(@_) {
		my $l = shift;
		if($l=~/HASH/i) {
			####
			## NOTE: This sort method is valid for window panel counts less than 10 integers
			## otherwise the sort process does not value 10 greater than 2
			####
			foreach my $panel (sort {$l->{$a} cmp $l->{$b} } keys %$l) {
				push @$p, $panel;
			}
		}
	}
	return $p;
}
sub _grids_to_panels {
	my $self = shift;
	my $g = $self->{WX_GUI_GRIDS_AREF}; # array ptr
	my $gp = $self->{WX_GUI_GRID_PANEL_MAP}; # hash ptr
	if(@_) {
		my $l = shift;
		if($l=~/HASH/i) {
			foreach my $grid (keys %$l) {
				push @$g, $grid;
				$gp->{$grid} = $l->{$grid};
			}
		}
	}
	return $gp;
}
sub _gui_grids {
	my $self = shift;
	my $g = $self->{WX_GUI_GRIDS_AREF};
	return $g;
}
sub status_message {
	my $self = shift;
	my $winframe = $self->_window_handle();
	my $message = '';
	if(@_) { $message = shift; }
	$winframe->{status_txt}->SetLabel($message);
	return 1;
}
sub start_display {
	my $self = shift;
	my $winframe = shift;
	my $settings = $_smgr->starter_display_settings();
	
	## Window settings
	my $window_wd = 1600;
	my $window_ht = 995;
	
	## panels

	## status
	my $status_ht = 35;
	my $status_wd = 1250;
	## control
	my $control_x = 0;
	my $control_y = $status_ht;
	my $control_ht = 550;
	my $control_wd = 1250;
	my $control_sp = 10;
	my $sidebar_wd = 425;
	my $rightsidetextbox_y = 300;
	my $rightsidetextbox_wd = 395;
	my $rightsidetextbox_ht = 400;
	
	my $window_pre_ht = $control_y + $control_sp + $control_ht + $control_sp;
	my $window_pre_wd = $status_wd+ $control_sp + $sidebar_wd + $control_sp;
	if($window_pre_ht > $window_ht) {
		$window_ht = $window_pre_ht;
	}
	if($window_pre_wd > $window_wd) {
		$window_wd = $window_pre_wd;
	}
	
	my $status_font_size = 14;
	my $row_font_size = 12;
	my $p_space = 5;
	my $r_space = 2;
	my $b_space = 5;
	my $row_ht = 30;
	my $btn_ht = 25;
	my $cell_1_wd = 250;
	my $cell_2_wd = 120;
	my $cell_3_wd = 75;
	my $cell_4_wd = 100;
	my $cell_5_wd = 50;
	my $cell_6_wd = 100;
	my $btn_1_wd = 80;
	my $btn_2_wd = 200;
	my $btn_start = 650;
	my $sfont = Wx::Font->new($status_font_size, wxFONTFAMILY_SWISS, wxNORMAL, wxNORMAL);
	my $rfont = Wx::Font->new($row_font_size, wxFONTFAMILY_SWISS, wxNORMAL, wxNORMAL);

	$winframe->{mainpanel} = Wx::Panel->new($winframe, -1, [0,0], [$status_wd,$status_ht], wxTAB_TRAVERSAL|wxBORDER_NONE); 

	$winframe->{status_txt} = Wx::StaticText->new( $winframe->{mainpanel},             # parent
									1,                  # id
									"Status field", # label
									[5, 5],           # position
									[$status_wd, $status_ht]            # size
									);
	$winframe->{status_txt}->SetFont($sfont);

	my $y_here = $control_y + $control_sp;
	$winframe->{control_panel} = Wx::Panel->new($winframe, -1, [0,$y_here], [$control_wd,$control_ht], #[-1,-1], 
		wxTAB_TRAVERSAL|wxBORDER_NONE); 

	$y_here = $control_ht + $y_here + $control_sp;
	$winframe->{view_panel} = Wx::Panel->new($winframe, -1, [0,$y_here], [$control_wd,$view_ht], #[-1,-1], 
		wxTAB_TRAVERSAL|wxALL); 

	my $x_here = $status_wd + $control_sp;
	my $ht_here = $y_here + $control_sp;
	$winframe->{rightside_panel} = Wx::Panel->new($winframe, -1, [$x_here,0], [$sidebar_wd,$ht_here], wxTAB_TRAVERSAL|wxBORDER_NONE); 
    $winframe->{rightsidetextbox} = Wx::TextCtrl->new( $winframe->{rightside_panel}, -1, '', [0,$rightsidetextbox_y], [$rightsidetextbox_wd,$rightsidetextbox_ht], wxTE_MULTILINE );
		
    $winframe->SetSize( [ $window_wd, $window_ht ] );

	return 1;
				
}
sub start_grid {
	my $self = shift;
	my $winframe = shift;

#	my $settings = $_smgr->starter_display_settings();
	

	## raw defaults
	my $start_pos_x = 0;
	my $start_pos_y = 0;
	my $dim_x = 1000;
	my $dim_y = 500;
	my $rows = 20;
	my $cols = 10;

	my $grid = Wx::Grid->new(
		$winframe->{gridpanel}, #parent
		-1, #id
		[$start_pos_x, $start_pos_y], #position
		[$dim_x, $dim_y] #dimensions
	);
	
	## store handle to grid object
	$self->_grid_handle($grid);
	
	$grid->CreateGrid(
		$rows, #rows
		$cols #cols
	);

	return 1;
}
sub format_grid {
	my $self = shift;
	my $grid = $self->_grid_handle();

#	my $settings = $_smgr->starter_display_settings();

	my $bcols = $self->{BIB_COL_REF};
	my $brows = $self->{BIB_ROW_REF};

	## raw defaults
	my $label = 'NA';
	my $cols = 6;
	my $rows = 1;
	my $min_size = 50;
	my $size = 100;
	my $head_col_ht = 0;
	my $row_label_wd = 0;
	# defaults
	my $row_ht = 10;
	my $font_size = 10;
	my $row_ct = 20;
	my $col_ct = 10;
	my $pair_ct = 5;
	my $size_a = 74;
	my $size_b = 125;
	
	$grid->SetColLabelSize($head_col_ht);
	$grid->SetRowLabelSize($row_label_wd);
	$grid->SetDefaultCellAlignment(wxALIGN_CENTRE,wxALIGN_CENTRE);

	my $font = Wx::Font->new($font_size, wxFONTFAMILY_SWISS, wxNORMAL, wxNORMAL);

	for(my $c=0; $c<$col_ct; $c=$c+2) {
		my $c2 = $c+1;
		$grid->SetColSize($c, $size_a);
		$grid->SetColSize($c2, $size_b);
	}
	
	#$variable->SetGridLineColour($self->colour( $control->grid_line_color ));

	my $ct = 1;
	for(my $r=0; $r<$row_ct; $r++) {
		for(my $c=0; $c<$col_ct; $c=$c+2) {
			my $cell_value = $ct;
			my $cell_value2 = "$r : $c";
			$grid->SetCellValue($r, $c, $cell_value);
			$grid->SetCellValue($r, $c+1, $cell_value2);
			$bib_ct++;
			$grid->SetCellFont($r,$c,$font);
			$grid->SetCellBackgroundColour($r, $c, Wx::Colour->new(255,255,128));
			$grid->SetReadOnly($r, $c);
		}
	}
		
	return 1;
}
sub format_cells {
	my $self = shift;
	my $grid = $self->_grid_handle();


	# defaults
	my $row_ht = 10;
	my $font_size = 10;
	my $first_row_ht = 20;
	my $align = 'center';

	# my $settings = $_smgr->starter_display_settings();
	# if(exists $settings->{cells}) {
		# $row_ht = $settings->{cells}->{row_height};
		# $font_size = $settings->{cells}->{font_pt_size};
		# $first_row_ht = $settings->{cells}->{first_row_height};
	# }

	my $font = Wx::Font->new($font_size, wxFONTFAMILY_SWISS, wxNORMAL, wxNORMAL);

	$grid->SetDefaultRowSize($row_ht,1);
	$grid->SetDefaultCellFont($font);
	$grid->SetRowMinimalHeight(0,$first_row_ht);
	$grid->SetRowSize(0,$first_row_ht);
	return 1;
}
sub ButtonClicked { 
	my( $winframe, $event ) = @_; 
	# Change the contents of $self->{txt}
	$winframe->{txt}->SetLabel("The button was clicked!"); 
} 
sub append_textbox {
	my( $self, $textbox, $text ) = @_;
	my $tb = $self->{ACTIVE_TEXT_BOXES};
	if($textbox) {
		if(exists $tb->{$textbox}) {
			if($text) {
				my $winframe = $self->_window_handle();
				$winframe->{$textbox}->AppendText("$text\n");
				return 1;
			}
			print "Warning! No text submitted to append to [$textbox]\n";
			return 0;
		}
		return 1;
	}
	print "Error! No label name submitted to append textbox at [".__LINE__."]\n";
	return 0;
}
sub input_field {
	my( $self, $field, $text ) = @_;
	my $tb = $self->{INPUT_BOX_FIELD};
	if($field) {
		my $winframe = $self->_window_handle();
		if(exists $tb->{$field}) {
			## continue...otherwise, ignore
			if(!$text) {
				$winframe->{$field}->GetValue(''); ## clear input field
				return 1;
			}
			if($text) {
				$winframe->{$field}->GetValue($text);
				$winframe->{$field}->SetLabel();
				return 1;
			}
		}
	}
	print "Error! No label name submitted to input field value set at [".__LINE__."]\n";
	return 0;
}
sub text_label {
	my( $self, $field, $text ) = @_;
	my $tb = $self->{ACTIVE_STATIC_TEXT}; 
	if($field) {
		my $winframe = $self->_window_handle();
		if(exists $tb->{$field}) {
			if(!$text) {
				$winframe->{$field}->SetLabel('');
				return 1;
			}
			if($text) {
				$winframe->{$field}->SetLabel("$text");
				return 1;
			}
		}
	}
	print "Error! No label name submitted to static text field setting set at [".__LINE__."]\n";
	return 0;
}

1;


####### File /SubDir/HeilApp/wxPOEDisplay2.pm
package wxPOEDisplay2;
#######################################
#
#######################################
use strict;
use warnings;

use vars qw(@ISA);
use Wx::Grid;
@ISA = qw(Wx::Frame);
use Wx qw(:everything);
@ISA = qw(Wx::Grid);

use Wx::Event qw(EVT_SIZE
                 EVT_MENU
                 EVT_IDLE
                 EVT_COMBOBOX
                 EVT_UPDATE_UI
                 EVT_TOOL_ENTER
				 EVT_BUTTON
				 EVT_LEFT_DCLICK
				 EVT_RIGHT_DOWN
				 EVT_CLOSE
				 EVT_GRID_CELL_CHANGED
				 EVT_TEXT_ENTER
);

sub new {
	my $proto = shift;
	my $class = ref($proto) || $proto;
	my $self  = {};
	$self->{NAME}     = undef;
	$self->{START_SECS}     = 0;
	$self->{WX_GUI_CONFIG_FILE} = 'Gui2Configure.yml';
	$self->{CONFIG_DIR} = 'conf/';
	$self->{DISPLAY_SETTINGS} = {};
	$self->{WX_GUI_SETTINGS} = {};
	$self->{WX_GUI_PANELS_AREF} = [];
	$self->{WX_GUI_GRIDS_AREF} = [];
	$self->{WX_GUI_GRID_PANEL_MAP} = {};
	$self->{ACTIVE_TEXT_BOXES} = {'righttextbox'=>1,'lefttextbox'=>1};
	$self->{ACTIVE_STATIC_TEXT} = {'status_text'=>1};
	$self->{INPUT_BOX_FIELD} = {};
	$self->{DISPLAY_WINDOW} = undef;
	$self->{PMGR_OBJECT} = undef;
	$self->{SMGR_OBJECT} = undef;
	$self->{DMGR_OBJECT} = undef;
	bless ($self, $class);

	my $window = shift;
	$self->_window_handle($window);										
	my $mgr = shift;
	$self->_pmgr_handle($mgr);
	$mgr = shift;
	$self->_smgr_handle($mgr);
	$mgr = shift;
	$self->_dmgr_handle($mgr);

	return $self;
}
sub _window_handle {
	my $self = shift;
	if(@_) { $self->{DISPLAY_WINDOW} = shift; }
	return $self->{DISPLAY_WINDOW};
}
sub _pmgr_handle {
	my $self = shift;
	if(@_) { $self->{PMGR_OBJECT} = shift; }
	return $self->{PMGR_OBJECT};
}
sub _smgr_handle {
	my $self = shift;
	if(@_) { $self->{SMGR_OBJECT} = shift; }
	return $self->{SMGR_OBJECT};
}
sub _dmgr_handle {
	my $self = shift;
	if(@_) { $self->{DMGR_OBJECT} = shift; }
	return $self->{DMGR_OBJECT};
}
sub wx_gui_config_file {
	my $self = shift;
	if(@_) { $self->{WX_GUI_CONFIG_FILE} = shift; }
	return $self->{WX_GUI_CONFIG_FILE};
}
sub set_wx_gui_settings {
	my $self = shift;
	
	my $_display_config_file = $self->{TS_CONFIG_DIR} . $self->wx_gui_config_file();
	my $s = $_pmgr->ts_load_file($_display_config_file);

	if(!exists $s->{display_config}) {
		print "\nERROR! Cannot set monitor display config settings! [$s] appears corrupt\n\n";
		exit;
	}
	my $d = $s->{display_config};
	if(exists $d->{panel_list}) {
		$self->_gui_panels($d->{panel_list});
	}
	if(exists $d->{grid_to_panel_map}) {
		$self->_grids_to_panels($d->{grid_to_panel_map});
	}
	$self->_set_gui_grids($d);
	$self->_wx_gui_settings($d);
	return 1;
}
sub _wx_gui_settings {
	my $self = shift;
	if(@_) { 
		$self->{WX_GUI_SETTINGS} = shift;
	}
	return $self->{WX_GUI_SETTINGS};
}
sub _set_gui_grids {
	my $self = shift;
	my $d = shift;
	my $gds = $self->_gui_grids();
	foreach my $gd (@$gds) {
		if(exists $d->{$gd}) {
			my $g_conf = $d->{$gd};
			## configure grids
		}
	}
	return 1;
}
sub _gui_panels {
	my $self = shift;
	my $p = $self->{WX_GUI_PANELS_AREF};
	if(@_) {
		my $l = shift;
		if($l=~/HASH/i) {
			####
			## NOTE: This sort method is valid for window panel counts less than 10 integers
			## otherwise the sort process does not value 10 greater than 2
			####
			foreach my $panel (sort {$l->{$a} cmp $l->{$b} } keys %$l) {
				push @$p, $panel;
			}
		}
	}
	return $p;
}
sub _grids_to_panels {
	my $self = shift;
	my $g = $self->{WX_GUI_GRIDS_AREF}; # array ptr
	my $gp = $self->{WX_GUI_GRID_PANEL_MAP}; # hash ptr
	if(@_) {
		my $l = shift;
		if($l=~/HASH/i) {
			foreach my $grid (keys %$l) {
				push @$g, $grid;
				$gp->{$grid} = $l->{$grid};
			}
		}
	}
	return $gp;
}
sub _gui_grids {
	my $self = shift;
	my $g = $self->{WX_GUI_GRIDS_AREF};
	return $g;
}
sub status_message {
	my $self = shift;
	my $winframe = $self->_window_handle();
	my $message = '';
	if(@_) { $message = shift; }
	$winframe->{status_txt}->SetLabel($message);
	return 1;
}
sub start_display {
	my $self = shift;
	my $winframe = shift;
	my $settings = $_smgr->starter_display_settings();
	
	## Window settings
	my $window_wd = 800;
	my $window_ht = 495;
	
	## panels

	## status
	my $status_ht = 35;
	my $status_wd = 750;
	## control
	my $control_x = 0;
	my $control_y = $status_ht;
	my $control_ht = 450;
	my $control_wd = 650;
	my $control_sp = 10;
	my $sidebar_wd = 150;
	my $rightsidetextbox_y = 200;
	my $rightsidetextbox_wd = 145;
	my $rightsidetextbox_ht = 200;
	
	my $window_pre_ht = $control_y + $control_sp + $control_ht + $control_sp;
	my $window_pre_wd = $status_wd+ $control_sp + $sidebar_wd + $control_sp;
	if($window_pre_ht > $window_ht) {
		$window_ht = $window_pre_ht;
	}
	if($window_pre_wd > $window_wd) {
		$window_wd = $window_pre_wd;
	}
	
	my $status_font_size = 14;
	my $row_font_size = 12;
	my $p_space = 5;
	my $r_space = 2;
	my $b_space = 5;
	my $row_ht = 30;
	my $btn_ht = 25;
	my $cell_1_wd = 250;
	my $cell_2_wd = 120;
	my $btn_start = 650;
	my $sfont = Wx::Font->new($status_font_size, wxFONTFAMILY_SWISS, wxNORMAL, wxNORMAL);
	my $rfont = Wx::Font->new($row_font_size, wxFONTFAMILY_SWISS, wxNORMAL, wxNORMAL);

	$winframe->{mainpanel} = Wx::Panel->new($winframe, -1, [0,0], [$status_wd,$status_ht], wxTAB_TRAVERSAL|wxBORDER_NONE); 

	$winframe->{status_txt} = Wx::StaticText->new( $winframe->{mainpanel},             # parent
									1,                  # id
									"Status field", # label
									[5, 5],           # position
									[$status_wd, $status_ht]            # size
									);
	$winframe->{status_txt}->SetFont($sfont);

	my $y_here = $control_y + $control_sp;
	$winframe->{control_panel} = Wx::Panel->new($winframe, -1, [0,$y_here], [$control_wd,$control_ht], #[-1,-1], 
		wxTAB_TRAVERSAL|wxBORDER_NONE); 

	$y_here = $control_ht + $y_here + $control_sp;
	$winframe->{view_panel} = Wx::Panel->new($winframe, -1, [0,$y_here], [$control_wd,$view_ht], #[-1,-1], 
		wxTAB_TRAVERSAL|wxALL); 

	my $x_here = $status_wd + $control_sp;
	my $ht_here = $view_ht + $y_here + $control_sp;
	$winframe->{rightside_panel} = Wx::Panel->new($winframe, -1, [$x_here,0], [$sidebar_wd,$ht_here], wxTAB_TRAVERSAL|wxBORDER_NONE); 
    $winframe->{rightsidetextbox} = Wx::TextCtrl->new( $winframe->{rightside_panel}, -1, '', [0,$rightsidetextbox_y], [$rightsidetextbox_wd,$rightsidetextbox_ht], wxTE_MULTILINE );
		
    $winframe->SetSize( [ $window_wd, $window_ht ] );

	return 1;
				
}
sub start_grid {
	my $self = shift;
	my $winframe = shift;

#	my $settings = $_smgr->starter_display_settings();
	

	## raw defaults
	my $start_pos_x = 0;
	my $start_pos_y = 0;
	my $dim_x = 1000;
	my $dim_y = 500;
	my $rows = 20;
	my $cols = 10;

	my $grid = Wx::Grid->new(
		$winframe->{gridpanel}, #parent
		-1, #id
		[$start_pos_x, $start_pos_y], #position
		[$dim_x, $dim_y] #dimensions
	);
	
	## store handle to grid object
	$self->_grid_handle($grid);
	
	$grid->CreateGrid(
		$rows, #rows
		$cols #cols
	);

	return 1;
}
sub format_grid {
	my $self = shift;
	my $grid = $self->_grid_handle();

#	my $settings = $_smgr->starter_display_settings();

	## raw defaults
	my $label = 'NA';
	my $cols = 6;
	my $rows = 1;
	my $min_size = 50;
	my $size = 100;
	my $head_col_ht = 0;
	my $row_label_wd = 0;
	# defaults
	my $row_ht = 10;
	my $font_size = 10;
	my $row_ct = 20;
	my $col_ct = 10;
	my $pair_ct = 5;
	my $size_a = 74;
	my $size_b = 125;
	
	$grid->SetColLabelSize($head_col_ht);
	$grid->SetRowLabelSize($row_label_wd);
	$grid->SetDefaultCellAlignment(wxALIGN_CENTRE,wxALIGN_CENTRE);

	my $font = Wx::Font->new($font_size, wxFONTFAMILY_SWISS, wxNORMAL, wxNORMAL);

	for(my $c=0; $c<$col_ct; $c=$c+2) {
		my $c2 = $c+1;
		$grid->SetColSize($c, $size_a);
		$grid->SetColSize($c2, $size_b);
	}
	
	#$variable->SetGridLineColour($self->colour( $control->grid_line_color ));

	my $ct = 1;
	for(my $r=0; $r<$row_ct; $r++) {
		for(my $c=0; $c<$col_ct; $c=$c+2) {
			my $cell_value = $ct;
			my $cell_value2 = "$r : $c";
			$grid->SetCellValue($r, $c, $cell_value);
			$grid->SetCellValue($r, $c+1, $cell_value2);
			$bib_ct++;
			$grid->SetCellFont($r,$c,$font);
			$grid->SetCellBackgroundColour($r, $c, Wx::Colour->new(255,255,128));
			$grid->SetReadOnly($r, $c);
		}
	}
		
	return 1;
}
sub format_cells {
	my $self = shift;
	my $grid = $self->_grid_handle();


	# defaults
	my $row_ht = 10;
	my $font_size = 10;
	my $first_row_ht = 20;
	my $align = 'center';

	# my $settings = $_smgr->starter_display_settings();
	# if(exists $settings->{cells}) {
		# $row_ht = $settings->{cells}->{row_height};
		# $font_size = $settings->{cells}->{font_pt_size};
		# $first_row_ht = $settings->{cells}->{first_row_height};
	# }

	my $font = Wx::Font->new($font_size, wxFONTFAMILY_SWISS, wxNORMAL, wxNORMAL);

	$grid->SetDefaultRowSize($row_ht,1);
	$grid->SetDefaultCellFont($font);
	$grid->SetRowMinimalHeight(0,$first_row_ht);
	$grid->SetRowSize(0,$first_row_ht);
	return 1;
}
sub ButtonClicked { 
	my( $winframe, $event ) = @_; 
	# Change the contents of $self->{txt}
	$winframe->{txt}->SetLabel("The button was clicked!"); 
} 
sub append_textbox {
	my( $self, $textbox, $text ) = @_;
	my $tb = $self->{ACTIVE_TEXT_BOXES};
	if($textbox) {
		if(exists $tb->{$textbox}) {
			if($text) {
				my $winframe = $self->_window_handle();
				$winframe->{$textbox}->AppendText("$text\n");
				return 1;
			}
			print "Warning! No text submitted to append to [$textbox]\n";
			return 0;
		}
		return 1;
	}
	print "Error! No label name submitted to append textbox at [".__LINE__."]\n";
	return 0;
}
sub input_field {
	my( $self, $field, $text ) = @_;
	my $tb = $self->{INPUT_BOX_FIELD};
	if($field) {
		my $winframe = $self->_window_handle();
		if(exists $tb->{$field}) {
			## continue...otherwise, ignore
			if(!$text) {
				$winframe->{$field}->GetValue(''); ## clear input field
				return 1;
			}
			if($text) {
				$winframe->{$field}->GetValue($text);
				$winframe->{$field}->SetLabel();
				return 1;
			}
		}
	}
	print "Error! No label name submitted to input field value set at [".__LINE__."]\n";
	return 0;
}
sub text_label {
	my( $self, $field, $text ) = @_;
	my $tb = $self->{ACTIVE_STATIC_TEXT}; 
	if($field) {
		my $winframe = $self->_window_handle();
		if(exists $tb->{$field}) {
			if(!$text) {
				$winframe->{$field}->SetLabel('');
				return 1;
			}
			if($text) {
				$winframe->{$field}->SetLabel("$text");
				return 1;
			}
		}
	}
	print "Error! No label name submitted to static text field setting set at [".__LINE__."]\n";
	return 0;
}

1;


####### File /SubDir/wxPOE_HeilApp.pm
package wxPOE_HeilApp;
#######################################
#
#######################################
use strict;
use warnings;
use SubDir::HeilApp::wxPOEFrame;
use SubDir::HeilApp::wxPOEDisplay;
use SubDir::HeilApp::wxPOEFrame2;
use SubDir::HeilApp::wxPOEDisplay2;

use base qw(Wx::App);
use vars qw(@frames);

sub OnInit {
    my $self = shift;
    Wx::InitAllImageHandlers();
	## create frame to hold display
    my $hframe = wxPOEFrame->new();
    my $h2frame = wxPOEFrame2->new();
    $self->SetTopWindow($hframe);
    $hframe->Show(1);
    $h2frame->Show(1);
    $h2frame->Show(1);
    1;
}

1;


##### main package in am_wxpoe_ps.pl
package main;

package main;
use POE;
use POE::Loop::Wx;
use POE::Session;

my $app = wxPOE_HeilApp->new();
POE::Session->create(
	inline_states => {
		_start => sub {
			$_[KERNEL]->yield('init_frame');
			$_[KERNEL]->yield('pulse');

		},
		init_frame => sub {
			if (@MonitorApp::frames) {
				foreach (@MonitorApp::frames) {
					$_->init_wframe_ns($_pmgr,$_smgr,$_dmgr);
					my $fid = $_->frameIdent();
					if($fid=~/**Match-to-framename-list**/i) {
						$_->signalPtr($_signal); ## set shared signal pointer, inside and outside Wx loop
						$_->CheckForInitSig(1); ## synchronize environments inside and outside Wx loop
						$_init_signal = 1; ## init signal state
						$_[KERNEL]->delay( init_start => 1 );
					}
						
				}
			}
		},
		init_start => sub {
			if (@MonitorApp::frames) {
				foreach (@MonitorApp::frames) {
					my $fid = $_->frameIdent();
					if($fid=~/**Match-to-framename-list**/i) {
						#push @init_levels, 1; push @init_levels, 2; etc., etc.
						$_[KERNEL]->delay( main_init_delay => 1);
					}
				}
			}
		},
		pulse => sub {
			if (@MonitorApp::frames) {
				foreach (@MonitorApp::frames) {
					$_->PoeEvent();
					my $fid = $_->frameIdent();
					if($fid=~/**Match-to-framename-list**/i) {
						if(scalar(keys $_signal)) {
							if(exists $_signal->{__some_signal_key__}) {
								if(!exists $_signal_latch->{__some_signal_key__}) {
									$_[KERNEL]->delay( main__some_signal__mgr => 1);
									$_signal_latch->{__some_signal_key__} = 1;
								}
							}
						}
					}
					if($fid=~/**Match-to-frame_with_shutdown_control**/i) {
						$_shutdown = $_->CheckForShutdownSig();
						if($_shutdown) {
							if(!$_shutdown_triggered) {
								$_shutdown_triggered = 1;
								$_[KERNEL]->yield("main_shutdown_signal_mgr");
							}
						}
					}
					$_->PulseEvent();

				}

				# relaunch pulse if frames still exist
				$_[KERNEL]->delay( pulse => 3 );
			}
		},
		main_shutdown_signal_mgr => \&main_shutdown_signal_mgr,
		main_shutdown_finish => \&main_shutdown_finish,
		main__some_signal__mgr => \&main__some_signal__mgr,
		main__some_signal__finish => \&main__some_signal__finish,
		main__some_signal__tasker => \&main__some_signal__tasker,
		main_init_delay => \&main_init_delay,
		force_kill => \&force_kill,
		wait_kill => \&wait_kill,
		srvr_socket_death => \&srvr_socket_death,
	}
);

POE::Kernel->loop_run();
POE::Kernel->run();

exit;

##########
# SOCKET #
##########

sub srvr_socket_birth { ## listening server not used unless called by the primary session
	my ($socket, $address, $port) = @_[ARG0, ARG1, ARG2];
	$address = inet_ntoa($address);

	print "== Socket created on inet address[$address]" if $carp;
	
	POE::Session->create(
		inline_states => {
			_start => \&srvr_socket_success,
			_stop  => \&srvr_socket_death,

			srvr_socket_death => \&srvr_socket_death,
		},
		args => [$socket, $address, $port],
	);
	
	return;
}
sub srvr_socket_death {
	my ($heap, $kernel) = @_[HEAP, KERNEL];
	if ($heap->{socket_wheel}) {
		print "= S = Socket is dead\n" if $carp;
		delete $heap->{socket_wheel};
	}
	if ($_[HEAP]->{shutdown_now}) {
		if($heap->{go_full_stop}) {
			$heap->{go_full_stop} = 0;
			full_stop($heap);
		}
	}
}
sub srvr_socket_success {
	my ($heap, $kernel, $connected_socket, $address, $port) = @_[HEAP, KERNEL, ARG0, ARG1, ARG2];

	print "= CONNECTION from $address : $port \n" if $carp;

	my $yaml = 'YAML';
	$heap->{socket_wheel} = POE::Wheel::ReadWrite->new(
		Handle => $connected_socket,
		Driver => POE::Driver::SysRW->new(),
		Filter => POE::Filter::Reference->new($yaml),
		InputEvent => 'srvr_socket_input',
		ErrorEvent => 'srvr_socket_death',
	);
	my $send = {'state'=>"welcome",'mess'=>$sconfig->{environment}->{local}->{init_server_message},'pulse'=>1};
	$heap->{socket_wheel}->put($send);
}
sub srvr_socket_input {
	my ($heap, $kernel, $buffer) = @_[HEAP, KERNEL, ARG0];

	print "== Data In (".scalar(keys %$buffer)."): " if $carp;

	if(exists $buffer->{state}) {
		if($buffer->{state}=!/__specify_state_protocol__/) {
			## do some work
		}
	}
	return;
}

sub main_shutdown_signal_mgr {
	my ($heap, $kernel) = @_[HEAP, KERNEL];

	print "==== in SHUTDOWN signal mgr; signal[$_shutdown] checkcount[$sd_check_count]\n" if $carp;
	$sd_check_count++;
	my $shutdown_ready = 0;
	my $this_signal = 0;
	if($_shutdown) {
		my $_clients = $_pmgr->poe_stored_clients();
		$clients_to_check = scalar(keys %$_clients);
		foreach my $s_key (keys %$_clients) {
			my $sess_id = $_pmgr->poe_client_session_ids($s_key);
			if(defined $_[KERNEL]->ID_id_to_session($sess_id)) {
				my $session = $_[KERNEL]->ID_id_to_session($sess_id);
				print "={$s_key CLIENT} client session still active [$sess_id]\n" if $carp;
				my $heap = $session->get_heap();
				if($heap->{shutdown}) {
					&make_poe_client($s_key,$this_signal);
				} elsif(!$heap->{connected}) {
					&make_poe_client($s_key,$this_signal);
				} else {
					## client connection was already started
					print " = posting shutdown\n" if $testing;

					$_[KERNEL]->post($session,"send_shutdown",$srvr_key);
				}
			} else {
				&make_poe_client($s_key,$this_signal);
			}
		}
	}
	return 1;
}
sub main_shutdown_finish {
	my ($heap, $kernel, $srvr) = @_[HEAP, KERNEL, ARG0];
	$sd_client_checks++;
	if($sd_client_checks >= $clients_to_check)) {
		print "= all clients shutdown count[$clients_to_check]\n" if $carp;
	
		sleep(1);
		## close wx windows
		if (@MonitorApp::frames) {
			foreach (@MonitorApp::frames) {
				$_->MakeWxShutdown();
			}
		}
		sleep(1);
		$k_count = 0;
		$kill_session = 0;
		$kernel->delay(wait_kill => 1);
		return;
	}
}
sub main__some_signal__mgr {
	my ($heap, $kernel) = @_[HEAP, KERNEL];

	$mgr_count++;
	print "  = signal manager; signal[".$_signal->{__some_signal_key__}."] checkcount[$mgr_count] done[$signal_done]\n" if $carp;
	if($_signal->{__some_signal_key__}==__?YOUR_SIGNAL_STATE?__) { ## refresh server list
	} elsif($_signal->{refresh}==2) { ## refresh daemon list
		if($signal_done) {
			$signal_done = 0;
			my $result = $_signal->{__some_signal_key__};
			$_[KERNEL]->delay(main__some_signal__mgr => undef);
			$_[KERNEL]->yield("main_refresh_finish",$result);
			return;
		}
		if(!exists $_signal_mgr_latch->{__some_signal_key__}) {
			$_signal_mgr_latch->{__some_signal_key__} = 1;
			$_[KERNEL]->yield("main_refresh_tasker",$_signal->{__some_signal_key__});
		}			
		return;
	}
	$_[KERNEL]->delay(main__some_signal__mgr => 1);
}
sub main__some_signal__finish {
	my ($heap, $kernel, $result) = @_[HEAP, KERNEL, ARG0];

	if (@MonitorApp::frames) {
		foreach (@MonitorApp::frames) {
			my $fid = $_->frameIdent();
			if($fid=~/**Match-to-framename-list**/i) {
				print "  ==== pass thru Signal for {__some_signal_key__} of [$result]\n" if $carp;
				$_->passThruSignal('__some_signal_key__',$result);
			}
			delete $_signal->{__some_signal_key__};
			delete $_signal_latch->{__some_signal_key__};
		}
	}
}
sub main__some_signal__tasker {
	my ($heap, $kernel, $type) = @_[HEAP, KERNEL, ARG0];

	if($type) {
		## create clients, do work....
	}
	return;
}
sub main_init_delay {
	$init_count++;
	if(scalar(@init_levels)) {
		$level_init = shift @init_levels;
		$_init_signal = '';
		if($level_init == 1) {
			$_[KERNEL]->delay(main_init_delay => 1);
			$_[KERNEL]->yield("__some_initial_method__");
			return;
		}
	}
	if($init_done) {
		if (@MonitorApp::frames) {
			foreach (@MonitorApp::frames) {
				my $fid = $_->frameIdent();
				if($fid=~/**Match-to-framename-list**/i) {
					$_->CheckForInitSig(0);
				}
			}
		}
		$_[KERNEL]->delay(main_init_delay => undef);
		return;
	}
	$_[KERNEL]->delay(main_init_delay => 1);
}

sub make_poe_client {
	my ($s_key, $signal_state) = @_;
	
	my $client_address = undef;
	my $client_port = undef;
	if($signal_state == __?SIGNAL_STATE?__) {
		$client_address = $_smgr->_network_address($s_key);
		$client_port = $_smgr->_server_port($s_key);
	}
	if(!$client_address or !$client_port) {
		print "\nERROR! At making POE client for [$s_key] No address or port value!\n";
		return 0;
	}

	my $yaml = 'YAML';
	POE::Component::Client::TCP->new(
		Alias => 'poe_client',
		RemoteAddress => $client_address,
		RemotePort    => $client_port,
		Filter => POE::Filter::Reference->new($yaml),
		Started       => sub {
			$_[HEAP]->{server_id} = $_[SENDER]->ID; ## should have an ID == 1
		},
		Connected => sub {
			my ($heap, $session) = @_[HEAP, SESSION];
			my $client_ID = $_[SESSION]->ID;
			$_pmgr->poe_clients($s_key,1);
			$_smgr->poe_client_session_ids($s_key,$client_ID);
		},
		ServerInput => \&__clnt_handler,

		Disconnected => sub {
			my ($kernel, $heap, $session) = @_[KERNEL, HEAP, SESSION];
		},
		InlineStates => {
			send_stuff => sub {
				my ($heap, $stuff) = @_[HEAP, ARG0];
						my $send = {};
						$send->{state} = 'data';
						
						## get stuff from $_dmgr...
						
						$heap->{server}->put($send);

				},
			send_shutdown => sub {
				my ($heap, $type) = @_[HEAP, ARG0];
						my $send = {};
						$send->{state} = 'shutdown';
						$send->{type} = 'force';
						if($type) {
							$send->{type} = $type;
						}
						print "    ={$srvr_key CLIENT send_shutdown} - sending state[".$send->{state}."] types[".$send->{type}."]\n" if $hb_debug_carp;
						$heap->{server}->put($send);
						return;
				},
			__clnt_handler => \&__clnt_handler,
			},
		);
}
sub __clnt_handler {
	my ($kernel, $heap, $session, $input) = @_[KERNEL, HEAP, SESSION, ARG0];
	
	## get input and do something....
	
	return;
}

sub wait_kill {
	$k_count++;
	print "timer fired! [$k_count] sess[$kill_session]\n" if $carp;
	if($kill_session==1) {
		$_[KERNEL]->delay(wait_kill => undef);
		$_[KERNEL]->yield("force_kill");
		return;
	}
	if(!exists $_[HEAP]->{socket_wheel}) {
		$_[HEAP]->{shutdown_now} = 1;
		$_[HEAP]->{go_full_stop} = 1;
		$_[KERNEL]->yield("srvr_socket_death");
	}
	if($k_count>$kill_ct_delay) {
		$kill_session=1;
	}
	$_[KERNEL]->delay(wait_kill => 1);
}
sub force_kill {
	my ($heap, $kernel) = @_[HEAP, KERNEL]; ##
	######
	## Shutdown takes place via killing the listening socket
	######
	print "...forcing kill...shutdown now[".$heap->{shutdown_now}."]\n";
	$heap->{shutdown_now} = 1;
	$heap->{go_full_stop} = 1;
	$_[KERNEL]->yield("srvr_socket_death");
}
sub full_stop {
	my $heap = $_[HEAP];
	print "...making shutdown.\n";
	warn "DIE = $SIG{__DIE__}";
	if ($heap->{listener}) {
		delete $heap->{listener};
		print "= L = Listener is dead\n" if $socket_carp;
	}
	if ($heap->{session}) {
		delete $heap->{session};
		print "= L = Session is dead\n" if $socket_carp;
	}

	&__pre_die_stop(1);
	
#	die "System is shutting down. G'bye!\n";
}
sub __pre_die_stop {
	my $warn = 0;
	if(@_) { $warn = shift; }
	if($warn) { warn "System is stopping all POE events.\n"; }

	## wipe the existing POE::Kernel clean
	$poe_kernel->stop();

	return;
}

