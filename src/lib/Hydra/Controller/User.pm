package Hydra::Controller::User;

use utf8;
use strict;
use warnings;
use base 'Hydra::Base::Controller::REST';
use Crypt::RandPasswd;
use Digest::SHA1 qw(sha1_hex);
use Hydra::Helper::Nix;
use Hydra::Helper::CatalystUtils;
use LWP::UserAgent;
use JSON;
use HTML::Entities;


__PACKAGE__->config->{namespace} = '';


sub login :Local :Args(0) :ActionClass('REST::ForBrowsers') { }

sub login_POST {
    my ($self, $c) = @_;

    my $username = $c->stash->{params}->{username} // "";
    my $password = $c->stash->{params}->{password} // "";

    error($c, "You must specify a user name.") if $username eq "";
    error($c, "You must specify a password.") if $password eq "";

    accessDenied($c, "Bad username or password.")
        if !$c->authenticate({username => $username, password => $password});

    $self->status_ok($c, entity => { });
}


sub logout :Local :Args(0) :ActionClass('REST::ForBrowsers') { }

sub logout_POST {
    my ($self, $c) = @_;
    $c->flash->{flashMsg} = "You are no longer signed in." if $c->user_exists();
    $c->logout;
    $self->status_no_content($c);
}


sub persona_login :Path('/persona-login') Args(0) {
    my ($self, $c) = @_;
    $c->stash->{json} = {};
    requirePost($c);

    my $assertion = $c->req->params->{assertion} or die;

    my $ua = new LWP::UserAgent;
    my $response = $ua->post(
        'https://verifier.login.persona.org/verify',
        { assertion => $assertion,
          audience => $c->uri_for('/')
        });
    error($c, "Did not get a response from Persona.") unless $response->is_success;

    my $d = decode_json($response->decoded_content) or die;
    error($c, "Persona says: $d->{reason}") if $d->{status} ne "okay";

    my $email = $d->{email} or die;

    my $user = $c->find_user({ username => $email });

    if (!$user) {
        $c->model('DB::Users')->create(
            { username => $email
            , password => "!"
            , emailaddress => $email,
            , type => "persona"
            });
        $user = $c->find_user({ username => $email }) or die;
    }

    $c->set_authenticated($user);

    $c->stash->{json}->{result} = "ok";
    $c->flash->{successMsg} = "You are now signed in as <tt>" . encode_entities($email) . "</tt>.";
}


sub captcha :Local Args(0) {
    my ($self, $c) = @_;
    $c->create_captcha();
}


sub isValidPassword {
    my ($password) = @_;
    return length($password) >= 6;
}


sub setPassword {
    my ($user, $password) = @_;
    $user->update({ password => sha1_hex($password) });
}


sub register :Local Args(0) {
    my ($self, $c) = @_;

    accessDenied($c, "User registration is currently not implemented.") unless isAdmin($c);

    $c->stash->{template} = 'user.tt';
    $c->stash->{create} = 1;
    return if $c->request->method ne "POST";

    my $userName = trim $c->req->params->{username};
    $c->stash->{username} = $userName;

    error($c, "You did not enter the correct digits from the security image.")
        unless isAdmin($c) || $c->validate_captcha($c->req->param('captcha'));

    error($c, "Your user name is invalid. It must start with a lower-case letter followed by lower-case letters, digits, dots or underscores.")
        if $userName !~ /^$userNameRE$/;

    error($c, "Your user name is already taken.")
        if $c->find_user({ username => $userName });

    txn_do($c->model('DB')->schema, sub {
        my $user = $c->model('DB::Users')->create(
            { username => $userName
            , password => "!"
            , emailaddress => "",
            , type => "hydra"
            });
        updatePreferences($c, $user);
    });

    unless ($c->user_exists) {
        $c->set_authenticated({username => $userName})
            or error($c, "Unable to authenticate the new user!");
    }

    $c->flash->{successMsg} = "User <tt>$userName</tt> has been created.";
    backToReferer($c);
}


sub updatePreferences {
    my ($c, $user) = @_;

    my $password = trim($c->req->params->{password} // "");
    if ($user->type eq "hydra" && ($user->password eq "!" || $password ne "")) {
        error($c, "You must specify a password of at least 6 characters.")
            unless isValidPassword($password);

        error($c, "The passwords you specified did not match.")
            if $password ne trim $c->req->params->{password2};

        setPassword($user, $password);
    }

    my $fullName = trim($c->req->params->{fullname} // "");
    error($c, "Your must specify your full name.") if $fullName eq "";

    my $emailAddress = trim($c->req->params->{emailaddress} // "");
    # FIXME: validate email address?

    $user->update(
        { fullname => $fullName
        , emailonerror => $c->stash->{params}->{"emailonerror"} ? 1 : 0
        });

    if (isAdmin($c)) {
        $user->update({ emailaddress => $emailAddress })
            if $user->type eq "hydra";

        $user->userroles->delete;
        $user->userroles->create({ role => $_ })
            foreach paramToList($c, "roles");
    }
}


sub currentUser :Path('/current-user') :ActionClass('REST') { }

sub currentUser_GET {
    my ($self, $c) = @_;

    requireUser($c);

    $self->status_ok(
        $c,
        entity => $c->model("DB::Users")->find($c->user->username)
    );
}


sub user :Chained('/') PathPart('user') CaptureArgs(1) {
    my ($self, $c, $userName) = @_;

    requireUser($c);

    accessDenied($c, "You do not have permission to edit other users.")
        if $userName ne $c->user->username && !isAdmin($c);

    $c->stash->{user} = $c->model('DB::Users')->find($userName)
        or notFound($c, "User $userName doesn't exist.");
}


sub deleteUser {
    my ($self, $c, $user) = @_;
    my ($project) = $c->model('DB::Projects')->search({ owner => $user->username });
    error($c, "User " . $user->username . " is still owner of project " . $project->name . ".")
        if defined $project;
    $c->logout() if $user->username eq $c->user->username;
    $user->delete;
}


sub edit :Chained('user') :Args(0) :ActionClass('REST::ForBrowsers') { }

sub edit_GET {
    my ($self, $c) = @_;

    my $user = $c->stash->{user};

    $c->stash->{template} = 'user.tt';

    $c->session->{referer} = $c->request->referer if !defined $c->session->{referer};

    $c->stash->{fullname} = $user->fullname;

    $c->stash->{emailonerror} = $user->emailonerror;
}

sub edit_POST {
    my ($self, $c) = @_;

    my $user = $c->stash->{user};

    $c->stash->{template} = 'user.tt';

    $c->session->{referer} = $c->request->referer if !defined $c->session->{referer};

    if (($c->stash->{params}->{submit} // "") eq "delete") {
        deleteUser($self, $c, $user);
        backToReferer($c);
    }

    if (($c->stash->{params}->{submit} // "") eq "reset-password") {
        error($c, "This user's password cannot be reset.") if $user->type ne "hydra";
        $c->stash->{json} = {};
        error($c, "No email address is set for this user.")
            unless $user->emailaddress;
        my $password = Crypt::RandPasswd->word(8,10);
        setPassword($user, $password);
        sendEmail($c,
            $user->emailaddress,
            "Hydra password reset",
            "Hi,\n\n".
            "Your password has been reset. Your new password is '$password'.\n\n".
            "You can change your password at " . $c->uri_for($self->action_for('edit'), [$user->username]) . ".\n\n".
            "With regards,\n\nHydra.\n"
        );
        return;
    }

    txn_do($c->model('DB')->schema, sub {
        updatePreferences($c, $user);
    });

    if ($c->request->looks_like_browser) {
        $c->flash->{successMsg} = "Your preferences have been updated.";
        backToReferer($c);
    } else {
        $self->status_no_content($c);
    }
}


sub dashboard :Chained('user') :Args(0) {
    my ($self, $c) = @_;
    $c->stash->{template} = 'dashboard.tt';

    # Get the N most recent builds for each starred job.
    $c->stash->{starredJobs} = [];
    foreach my $j ($c->stash->{user}->starredjobs->search({}, { order_by => ['project', 'jobset', 'job'] })) {
        my @builds = $j->job->builds->search(
            { },
            { rows => 20, order_by => "id desc" });
        push $c->stash->{starredJobs}, { job => $j->job, builds => [@builds] };
    }
}


1;
