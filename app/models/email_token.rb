# frozen_string_literal: true

class EmailToken < ActiveRecord::Base
  class TokenAccessError < StandardError; end

  belongs_to :user

  validates :user_id, :email, :token_hash, presence: true

  scope :unconfirmed, -> { where(confirmed: false) }
  scope :active, -> { where(expired: false).where('created_at >= ?', SiteSetting.email_token_valid_hours.hours.ago) }

  after_initialize do
    if self.token_hash.blank?
      @token ||= SecureRandom.hex
      self.token = @token
      self.token_hash = self.class.hash_token(@token)
    end
  end

  before_validation do
    self.email = self.email.downcase if self.email
  end

  before_save do
    if self.scope.blank?
      STDERR.puts "EmailToken has an empty scope"
      caller.each { |x| STDERR.puts "    #{x}" if x.include?('discourse') }
    end
  end

  after_create do
    EmailToken
      .where(user_id: self.user_id)
      .where.not(id: self.id)
      .update_all(expired: true)
  end

  def self.scopes
    @scopes ||= Enum.new(
      signup: 1,
      forgot_password: 2,
      password_reset: 3,
      email_login: 4,
      admin_login: 5,
      old_email: 6,
      new_email: 7,
    )
  end

  def token
    raise TokenAccessError.new if @token.blank?
    self[:token]
  end

  def self.confirm(token, skip_reviewable: false)
    User.transaction do
      email_token = confirmable(token)
      return if email_token.blank?

      email_token.update!(confirmed: true)

      user = email_token.user
      user.send_welcome_message = !user.active?
      user.email = email_token.email
      user.active = true
      user.custom_fields.delete('activation_reminder')
      user.save!
      user.create_reviewable if !skip_reviewable
      user.set_automatic_groups
      DiscourseEvent.trigger(:user_confirmed_email, user)
      Invite.redeem_from_email(user.email)

      user.reload
    end
  rescue ActiveRecord::RecordInvalid
    # If the user's email is already taken, just return nil (failure)
  end

  def self.confirmable(token)
    return nil if token.blank?

    unconfirmed.active.includes(:user).where(token_hash: hash_token(token)).first
  end

  def self.enqueue_signup_email(email_token, to_address: nil)
    Jobs.enqueue(
      :critical_user_email,
      type: :signup,
      user_id: email_token.user_id,
      email_token: email_token.token,
      to_address: to_address
    )
  end

  def self.hash_token(token)
    Digest::SHA256.hexdigest(token)
  end
end

# == Schema Information
#
# Table name: email_tokens
#
#  id         :integer          not null, primary key
#  user_id    :integer          not null
#  email      :string           not null
#  token      :string           not null
#  confirmed  :boolean          default(FALSE), not null
#  expired    :boolean          default(FALSE), not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  token_hash :string           not null
#  scope      :integer
#
# Indexes
#
#  index_email_tokens_on_token    (token) UNIQUE
#  index_email_tokens_on_user_id  (user_id)
#
