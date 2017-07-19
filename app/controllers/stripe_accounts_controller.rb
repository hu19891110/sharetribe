class StripeAccountsController < ApplicationController
  before_action do |controller|
    controller.ensure_logged_in t("layouts.notifications.you_must_log_in_to_view_your_settings")
  end

  before_action :ensure_stripe_enabled

  def show
    m_account = accounts_api.get(
      community_id: @current_community.id,
      person_id: @current_user.id
    ).data

    stripe_account_form = StripeCreateAccountForm.new(m_account || {})
    stripe_bank_form = m_account.present? ? StripeBankAccountForm.new(m_account) : nil

    render('show', locals: build_view_locals(stripe_account_form, m_account, stripe_bank_form))
  end

  def create
    m_account = accounts_api.get(
      community_id: @current_community.id,
      person_id: @current_user.id
    ).data

    if m_account.present? && m_account[:stripe_seller_id].present? && params[:update] != '1'
      redirect_to action: :show
      return
    end

    if params[:update] == '1'
      address_attrs = params.require(:stripe_create_account_form).permit(:address_line1, :address_city, :address_state, :address_postal_code)
      result = accounts_api.update_address(community_id: @current_community.id, person_id: @current_user.id, body: address_attrs)
      if !result[:success]
        flash[:error] = result[:error_msg]
      end
      redirect_to action: :show
      return
    end

    stripe_account_form = parse_create_params(params[:stripe_create_account_form])
    if stripe_account_form.valid?
      account_attrs = stripe_account_form.to_hash
      account_attrs[:tos_ip] = request.remote_ip
      account_attrs[:tos_date] = Time.now
      result = accounts_api.create(community_id: @current_community.id, person_id: @current_user.id, body: account_attrs)
      if result[:success]
        redirect_to action: :show
        return
      else
        flash[:error] = result[:error_msg]
      end
    end
    render('show', locals: build_view_locals(stripe_account_form, m_account))
  end

  def update
    m_account = accounts_api.get(
      community_id: @current_community.id,
      person_id: @current_user.id
    ).data

    if !m_account.present? || !m_account[:stripe_seller_id].present?
      redirect_to action: :show
      return
    end


    stripe_account_form = StripeCreateAccountForm.new(m_account || {})

    stripe_bank_form = parse_bank_params(params[:stripe_bank_account_form])

    if stripe_bank_form.valid?
      account_attrs = stripe_bank_form.to_hash
      result = accounts_api.create_bank_account(community_id: @current_community.id, person_id: @current_user.id, body: account_attrs)
      if result[:success]
        redirect_to action: :show
        return
      else
        flash[:error] = result[:error_msg]
      end
    end
    render('show', locals: build_view_locals(stripe_account_form, m_account, stripe_bank_form))
  end

  def send_verification
    m_account = accounts_api.get(
      community_id: @current_community.id,
      person_id: @current_user.id
    ).data

    if !m_account.present? && !m_account[:stripe_seller_id].present?
      return redirect_to action: :show
    end

    if params[:personal_id_number].present? && params[:document].present?
      accounts_api.send_verification(community_id: @current_community.id, person_id: @current_user.id, personal_id_number: params[:personal_id_number], file: params[:document].path)
    end

    redirect_to action: :show
  end

  private

  STRIPE_COUNTRIES = StripeService::Store::StripeAccount::COUNTRIES

  STRIPE_COUNTRY_NAMES = StripeService::Store::StripeAccount::COUNTRY_NAMES

  StripeCreateAccountForm = FormUtils.define_form("StripeCreateAccountForm",
        :first_name,
        :last_name,
        :address_country,
        :address_city,
        :address_line1,
        :address_postal_code,
        :address_state,
        :birth_date,
        :ssn_last_4,
        :tos).with_validations do
    validates_presence_of :first_name, :last_name,
        :address_country, :address_city, :address_line1, :address_postal_code, :address_state,
        :birth_date, :ssn_last_4
    validates_inclusion_of :address_country, in: STRIPE_COUNTRIES
    validates_confirmation_of :tos
  end

  StripeAddressForm = FormUtils.define_form("StripeAddressForm",
        :address_city,
        :address_line1,
        :address_postal_code,
        :address_state).with_validations do
    validates_presence_of :address_city, :address_line1, :address_postal_code, :address_state
  end

  StripeBankAccountForm = FormUtils.define_form("StripeBankAccountForm",
        :bank_country,
        :bank_currency,
        :bank_account_holder_name,
        :bank_account_number,
        :bank_routing_number
        ).with_validations do
    validates_presence_of :bank_country,
        :bank_currency,
        :bank_account_holder_name,
        :bank_account_number
    validates_inclusion_of :bank_country, in: STRIPE_COUNTRIES
  end

  def build_view_locals(stripe_account_form, m_account, stripe_bank_form = nil)
    @selected_left_navi_link = "stripe_payments"

    community_ready_for_payments = StripeHelper.community_ready_for_payments?(@current_community)
    unless community_ready_for_payments
      flash.now[:warning] = t("stripe_accounts.admin_account_not_connected",
                            contact_admin_link: view_context.link_to(
                              t("stripe_accounts.contact_admin_link_text"),
                                new_user_feedback_path)).html_safe
    end

    community_currency = @current_community.currency
    payment_settings = payment_settings_api.get_active_by_gateway(community_id: @current_community.id, payment_gateway: :stripe).maybe.get
    community_country_code = LocalizationUtils.valid_country_code(@current_community.country)

    if m_account && m_account[:stripe_seller_id].present?
      seller_account = stripe_api.get_seller_account(@current_community.id, m_account[:stripe_seller_id])
    end

    if m_account && m_account[:stripe_customer_id].present?
      customer_account = stripe_api.get_customer_account(@current_community.id, m_account[:stripe_customer_id])
    end

    {
      community_ready_for_payments: community_ready_for_payments,
      left_hand_navigation_links: settings_links_for(@current_user, @current_community),
      commission_from_seller: t("stripe_accounts.commission", commission: payment_settings[:commission_from_seller]),
      minimum_commission: Money.new(payment_settings[:minimum_transaction_fee_cents], community_currency),
      commission_type: payment_settings[:commission_type],
      currency: community_currency,
      available_countries: STRIPE_COUNTRY_NAMES,
      stripe_account_form: stripe_account_form,
      m_account: m_account,
      stripe_bank_form: stripe_bank_form,
      publishable_key: payment_settings[:api_publishable_key],
      customer_account: customer_account,
      seller_account: seller_account,
    }
  end

  def payment_settings_api
    TransactionService::API::Api.settings
  end

  def accounts_api
    StripeService::API::Api.accounts
  end

  # Before filter
  def ensure_stripe_enabled
    unless StripeHelper.stripe_active?(@current_community.id)
      flash[:error] = t("stripe_accounts.new.stripe_not_enabled")
      redirect_to person_settings_path(@current_user)
    end
  end

  def parse_create_params(params)
    allowed_params = params.permit(*StripeCreateAccountForm.keys)
    allowed_params[:birth_date] = params[:birth_date].to_date
    StripeCreateAccountForm.new(allowed_params)
  end

  def parse_bank_params(params)
    allowed_params = params.permit(*StripeBankAccountForm.keys)
    StripeBankAccountForm.new(allowed_params)
  end

  def stripe_api
    StripeService::API::Api.wrapper
  end

  def payments_api
    StripeService::API::Api.payments
  end
end
