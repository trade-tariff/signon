class User < ApplicationRecord
  include Roles

  self.include_root_in_json = true

  SUSPENSION_THRESHOLD_PERIOD = 45.days
  UNSUSPENSION_GRACE_PERIOD = 7.days

  MAX_2SV_LOGIN_ATTEMPTS = 10
  MAX_2SV_DRIFT_SECONDS = 30
  REMEMBER_2SV_SESSION_FOR = 30.days

  USER_STATUS_SUSPENDED = "suspended".freeze
  USER_STATUS_INVITED = "invited".freeze
  USER_STATUS_LOCKED = "locked".freeze
  USER_STATUS_ACTIVE = "active".freeze
  USER_STATUSES = [USER_STATUS_SUSPENDED,
                   USER_STATUS_INVITED,
                   USER_STATUS_LOCKED,
                   USER_STATUS_ACTIVE].freeze

  devise :database_authenticatable,
         :recoverable,
         :trackable,
         :validatable,
         :timeoutable,
         :lockable, # devise core model extensions
         :invitable,    # in devise_invitable gem
         :suspendable,  # in signon/lib/devise/models/suspendable.rb
         :zxcvbnable,
         :encryptable,
         :confirmable,
         :password_archivable # in signon/lib/devise/models/password_archivable.rb

  validates :name, presence: true
  validates :reason_for_suspension, presence: true, if: proc { |u| u.suspended? }
  validate :organisation_admin_belongs_to_organisation
  validate :email_is_ascii_only

  has_many :authorisations, class_name: "Doorkeeper::AccessToken", foreign_key: :resource_owner_id
  has_many :application_permissions, class_name: "UserApplicationPermission", inverse_of: :user
  has_many :supported_permissions, through: :application_permissions
  has_many :batch_invitations
  belongs_to :organisation

  before_validation :fix_apostrophe_in_email
  after_initialize :generate_uid
  after_create :update_stats
  before_save :set_2sv_for_admin_roles
  before_save :mark_two_step_flag_changed
  before_save :update_password_changed

  scope :web_users, -> { where(api_user: false) }
  scope :not_suspended, -> { where(suspended_at: nil) }
  scope :with_role, ->(role_name) { where(role: role_name) }
  scope :with_permission, ->(permission_id) { joins(:supported_permissions).where("supported_permissions.id = ?", permission_id) }
  scope :with_organisation, ->(org_id) { where(organisation_id: org_id) }
  scope :filter_by_name, ->(filter_param) { where("users.email like ? OR users.name like ?", "%#{filter_param.strip}%", "%#{filter_param.strip}%") }
  scope :last_signed_in_on, ->(date) { web_users.not_suspended.where("date(current_sign_in_at) = date(?)", date) }
  scope :last_signed_in_before, ->(date) { web_users.not_suspended.where("date(current_sign_in_at) < date(?)", date) }
  scope :last_signed_in_after, ->(date) { web_users.not_suspended.where("date(current_sign_in_at) >= date(?)", date) }
  scope :not_recently_unsuspended, -> { where(["unsuspended_at IS NULL OR unsuspended_at < ?", UNSUSPENSION_GRACE_PERIOD.ago]) }
  scope :with_access_to_application, ->(application) { UsersWithAccess.new(self, application).users }
  scope :with_2sv_enabled,
        lambda { |enabled|
          enabled = ActiveRecord::Type::Boolean.new.cast(enabled)
          where("otp_secret_key IS #{'NOT' if enabled} NULL")
        }

  scope :with_status,
        lambda { |status|
          case status
          when USER_STATUS_SUSPENDED
            where.not(suspended_at: nil)
          when USER_STATUS_INVITED
            where.not(invitation_sent_at: nil).where(invitation_accepted_at: nil)
          when USER_STATUS_LOCKED
            where.not(locked_at: nil)
          when USER_STATUS_ACTIVE
            where(suspended_at: nil, locked_at: nil)
              .where(arel_table[:invitation_sent_at].eq(nil)
                .or(arel_table[:invitation_accepted_at].not_eq(nil)))
          else
            raise NotImplementedError, "Filtering by status '#{status}' not implemented."
          end
        }

  def prompt_for_2sv?
    return false if has_2sv?

    require_2sv?
  end

  def event_logs
    EventLog.where(uid: uid).order(created_at: :desc).includes(:user_agent)
  end

  def generate_uid
    self.uid ||= UUID.generate
  end

  def invited_but_not_accepted
    !invitation_sent_at.nil? && invitation_accepted_at.nil?
  end

  def permissions_for(application)
    application_permissions
      .joins(:supported_permission)
      .where(application_id: application.id)
      .order("supported_permissions.name")
      .pluck(:name)
  end

  # Avoid N+1 queries by using the relations eager loaded with `includes()`.
  def eager_loaded_permission_for(application)
    application_permissions.select { |p| p.application_id == application.id }.map(&:supported_permission).map(&:name)
  end

  def permission_ids_for(application)
    application_permissions.where(application_id: application.id).pluck(:supported_permission_id)
  end

  def has_access_to?(application)
    application_permissions.detect { |permission| permission.supported_permission_id == application.signin_permission.id }
  end

  def permissions_synced!(application)
    application_permissions.where(application_id: application.id).update_all(last_synced_at: Time.zone.now)
  end

  def authorised_applications
    authorisations.group_by(&:application).map(&:first)
  end
  alias_method :applications_used, :authorised_applications

  def grant_application_permission(application, supported_permission_name)
    grant_application_permissions(application, [supported_permission_name]).first
  end

  def grant_application_permissions(application, supported_permission_names)
    supported_permission_names.map do |supported_permission_name|
      supported_permission = SupportedPermission.find_by(application_id: application.id, name: supported_permission_name)
      grant_permission(supported_permission)
    end
  end

  def grant_permission(supported_permission)
    application_permissions.where(supported_permission_id: supported_permission.id).first_or_create!
  end

  # This overrides `Devise::Recoverable` behavior.
  def self.send_reset_password_instructions(attributes = {})
    user = User.find_by(email: attributes[:email])
    if user.present? && user.suspended?
      UserMailer.notify_reset_password_disallowed_due_to_suspension(user).deliver_later
      user
    elsif user.present? && user.invited_but_not_yet_accepted?
      UserMailer.notify_reset_password_disallowed_due_to_unaccepted_invitation(user).deliver_later
      user
    else
      super
    end
  end

  def unusable_account?
    invited_but_not_yet_accepted? || suspended? || access_locked?
  end

  # Required for devise_invitable to set role and permissions
  def self.inviter_role(inviter)
    inviter.nil? ? :default : inviter.role.to_sym
  end

  def invite!(*args)
    # For us, a user is "confirmed" when they're created, even though this is
    # conceptually confusing.
    # It means that the password reset flow works when you've been invited but
    # not yet accepted.
    # Devise Invitable used to behave this way and then changed in v1.1.1
    self.confirmed_at = Time.zone.now
    super(*args)
  end

  # Override Devise so that, when a user has been invited with one address
  # and then it is changed, we can send a new invitation email, rather than
  # a confirmation email (and hence they'll be in the correct flow re setting
  # their first password)
  def postpone_email_change?
    if invited_but_not_yet_accepted?
      false
    else
      super
    end
  end

  def invited_but_not_yet_accepted?
    invitation_sent_at.present? && invitation_accepted_at.nil?
  end

  def update_stats
    GovukStatsd.increment("users.created")
  end

  # Override Devise::Model::Lockable#lock_access! to add event logging
  def lock_access!(opts = {})
    event = locked_reason == :two_step ? EventLog::TWO_STEP_LOCKED : EventLog::ACCOUNT_LOCKED
    EventLog.record_event(self, event)

    super
  end

  def status
    return USER_STATUS_SUSPENDED if suspended?

    if !api_user? && invited_but_not_yet_accepted?
      return USER_STATUS_INVITED
    end

    return USER_STATUS_LOCKED if access_locked?

    USER_STATUS_ACTIVE
  end

  def manageable_roles
    "Roles::#{role.camelize}".constantize.manageable_roles
  end

  # Make devise send all emails using ActiveJob
  def send_devise_notification(notification, *args)
    devise_mailer.send(notification, self, *args).deliver_later
  end

  def need_two_step_verification?
    has_2sv?
  end

  def set_2sv_for_admin_roles
    return if Rails.application.config.instance_name.present?

    self.require_2sv = true if role_changed? && (admin? || superadmin?)
  end

  def authenticate_otp(code)
    totp = ROTP::TOTP.new(otp_secret_key)
    result = totp.verify(code, drift_behind: MAX_2SV_DRIFT_SECONDS)

    if result
      update!(second_factor_attempts_count: 0)
      EventLog.record_event(self, EventLog::TWO_STEP_VERIFIED)
    else
      increment!(:second_factor_attempts_count)
      EventLog.record_event(self, EventLog::TWO_STEP_VERIFICATION_FAILED)
      lock_access! if max_2sv_login_attempts?
    end

    result
  end

  def locked_reason
    if max_2sv_login_attempts?
      :two_step
    else
      :password
    end
  end

  def max_2sv_login_attempts?
    second_factor_attempts_count.to_i >= MAX_2SV_LOGIN_ATTEMPTS.to_i
  end

  def unlock_access!(*args)
    super
    update!(second_factor_attempts_count: 0)
  end

  def has_2sv?
    otp_secret_key.present?
  end

  def reset_2sv!(initiating_superadmin)
    transaction do
      self.otp_secret_key = nil
      self.require_2sv = true
      save!

      EventLog.record_event(
        self,
        EventLog::TWO_STEP_RESET,
        initiator: initiating_superadmin,
      )
    end
  end

  def send_two_step_flag_notification?
    require_2sv? && two_step_flag_changed?
  end

  def belongs_to_gds?
    organisation.try(:content_id).to_s == Organisation::GDS_ORG_CONTENT_ID
  end

private

  def two_step_flag_changed?
    @two_step_flag_changed
  end

  def mark_two_step_flag_changed
    @two_step_flag_changed = require_2sv_changed?
    true
  end

  def organisation_admin_belongs_to_organisation
    if %w[organisation_admin super_organisation_admin].include?(role) && organisation_id.blank?
      errors.add(:organisation_id, "can't be 'None' for #{role.titleize}")
    end
  end

  def email_is_ascii_only
    errors.add(:email, "can't contain non-ASCII characters") unless email.blank? || email.ascii_only?
  end

  def fix_apostrophe_in_email
    email.tr!("’", "'") if email.present? && email_changed?
  end

  def update_password_changed
    self.password_changed_at = Time.zone.now if (new_record? || encrypted_password_changed?) && !password_changed_at_changed?
  end
end
