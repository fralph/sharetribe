module TransactionService::Transaction

  DataTypes = TransactionService::DataTypes::Transaction
  TransactionModel = ::Transaction

  module_function

  def query(transaction_id)
    model_to_entity(TransactionModel.find(transaction_id))
  end

  def create(transaction_opts)
    opts = transaction_opts[:transaction]

    #TODO this thing should come through transaction_opts
    listing = Listing.find(opts[:listing_id])

    transaction = TransactionModel.new(
      community_id: opts[:community_id],
      listing_id: opts[:listing_id],
      starter_id: opts[:starter_id],
      payment_gateway: opts[:payment_gateway],
      commission_from_seller: opts[:commission_from_seller],
      minimum_commission_cents: Maybe(opts[:minimum_commission_cents]).or_else(0),
      minimum_commission_currency: listing.currency)

    conversation = transaction.build_conversation(
      community_id: opts[:community_id],
      listing_id: opts[:listing_id])

    conversation.participations.build(
      person_id: opts[:listing_author_id],
      is_starter: false,
      is_read: false)

    conversation.participations.build(
      person_id: opts[:starter_id],
      is_starter: true,
      is_read: true)

    #TODO: check this one out, how to handle pts[:content]?, it's missing from documentation
    if opts[:content].present?
      conversation.messages.build({
          content: opts[:content],
          sender_id: opts[:starter_id]})
    end

    transaction.save!

    #TODO: Fix to more sustainable solution (use model_to_entity, and add paypal and braintree relevant fields)
    #transition info is now added in controllers
    DataTypes.create_transaction_response(opts.merge({
          id: transaction.id,
          conversation_id: conversation.id,
          created_at: transaction.created_at,
          updated_at: transaction.updated_at
        }))
  end

  def preauthorize
    raise "Not implemented"
  end

  def reject
    raise "Not implemented"
  end

  def complete_preauthorization(transaction_id)
    transaction = MarketplaceService::Transaction::Query.transaction(transaction_id)
    payment_type = MarketplaceService::Community::Query.payment_type(transaction[:community_id])

    case payment_type
    when :braintree
      BraintreeService::Payments::Command.submit_to_settlement(transaction[:id], transaction[:community_id])
      MarketplaceService::Transaction::Command.transition_to(transaction[:id], :paid)

      transaction = query(transaction[:id])

      Result::Success.new(
        DataTypes.create_transaction_response(transaction))
    when :paypal
      paypal_payments = PaypalService::API::Api.payments

      payment_response = paypal_payments.get_payment(transaction[:community_id], transaction[:id])
      if payment_response[:success]
        payment = payment_response[:data]
        capture_response = paypal_payments.full_capture(
          transaction[:community_id],
          transaction[:id],
          PaypalService::API::DataTypes.create_payment_info({ payment_total: payment[:authorization_total] }))

        if capture_response[:success]
          next_state =
            if capture_response[:data][:payment_status] == :completed
              :paid
            else
              :pending_ext
            end

          MarketplaceService::Transaction::Command.transition_to(transaction[:id], next_state, pending_reason: capture_response[:data][:pending_reason])

          transaction = query(transaction[:id])
          Result::Success.new(
            DataTypes.create_transaction_response(transaction, DataTypes.create_paypal_complete_preauthorization_fields(pending_reason: capture_response[:data][:pending_reason])))
        else
          Result::Error.new("An error occured while trying to complete preauthorized Paypal payment")
        end
      end

    end
  end

  def invoice
    raise "Not implemented"
  end

  def pay_invoice
    raise "Not implemented"
  end

  def complete(transaction_id)
    MarketplaceService::Transaction::Command.transition_to(transaction_id, :confirmed)

    transaction = query(transaction_id)
    MarketplaceService::Transaction::Command.mark_as_unseen_by_other(transaction_id, transaction[:listing_author_id])
    payment_type = MarketplaceService::Community::Query.payment_type(transaction[:community_id])

    case payment_type
    when :paypal
      payments_api = PaypalService::API::Api.payments

      payment = payments_api.get_payment(transaction[:community_id], transaction_id)
      commission_total = transaction[:commission_total]
      charge_request =
        {
          transaction_id: transaction_id,
          commission_total: commission_total,
          payment_name: I18n.t("paypal.transaction.commission_payment_name", transaction[:listing_title]),
          payment_desc: I18n.t("paypal.transaction.commission_payment_description", transaction[:listing_title])
        }

      billing_agreement_api = PaypalService::API::Api.billing_agreements

      charge_commission_res = billing_agreement_api.charge_commission(transaction[:community_id], transaction[:listing_author_id], charge_request)
      if charge_commission_res.success
        Result::Success.new(charge_commission_res[:data])
      else
        Result::Error.new("An error occured while trying to complete Paypal commission payment")
      end
    else
      Result::Success.new(transaction)
    end
  end

  def cancel(transaction_id)
    MarketplaceService::Transaction::Command.transition_to(transaction_id, :canceled)

    transaction = query(transaction_id)
    MarketplaceService::Transaction::Command.mark_as_unseen_by_other(transaction_id,transaction[:listing_author_id])

    Result::Success.new(transaction)
  end

  def token_cancelled(token)
    Transaction.where(community_id: token[:community_id], id: token[:transaction_id]).destroy_all
  end

  # private

  # Warning!
  # This is only an intermediate solution. Ideally, we would store all the required
  # transaction data in transaction service, but now we have to fetch the data from here and there.
  # However, this method is only used to get the API interface right, even though the data model
  # doesn't match the interface.
  #
  def model_to_entity(model)
    payment_process =
      if !model.listing.transaction_type.price_field?
        :none
      else
        if model.listing.transaction_type.preauthorize_payment?
          :preauthorize
        else
          :postpay
        end
      end

    payment_total =
      case model.payment_gateway.to_sym
      when :checkout, :braintree
        Maybe(model).payment.total_sum.or_else(nil)
      when :paypal
        payments_api = PaypalService::API::Api.payments
        payment = payments_api.get_payment(model.community_id, model.id)

        Maybe(payment).select { |p| p[:success] }[:data][:payment_total].or_else(nil)
      end

    checkout_details = checkout_details(model)
    DataTypes.create_transaction({
        id: model.id,
        payment_process: payment_process,
        payment_gateway: model.payment_gateway.to_sym,
        community_id: model.community_id,
        starter_id: model.starter.id,
        listing_id: model.listing.id,
        listing_title: model.listing.title,
        listing_price: model.listing.price,
        listing_author_id: model.listing.author.id,
        listing_quantity: 1, #TODO fixme for booking
        automatic_confirmation_after_days: model.automatic_confirmation_after_days,
        last_transition_at: model.last_transition_at,
        current_state: model.current_state.to_sym,
        payment_total: payment_total,
        minimum_commission: model.minimum_commission,
        commission_from_seller: Maybe(model.commission_from_seller).or_else(0),
        checkout_total:   checkout_details[:total_price],
        commission_total: checkout_details[:commission_total]})
  end

  def checkout_details(model)

    case model.payment_gateway.to_sym
    when :paypal
      payments_api = PaypalService::API::Api.payments
      payment = payments_api.get_payment(model.community.id, model.id)
      total =
        if payment[:data][:payment_total].present?
          payment[:data][:payment_total]
        elsif payment[:data][:authorization_total].present?
          payment[:data][:authorization_total]
        else
          model.listing_price * 1 #TODO fixme for booking (model.listing_quantity)
        end
      { total_price: total, commission_total: calculate_commission(total, model.commission_from_seller, model.minimum_commission) }
    else
      total = model.listing.price * 1 #TODO fixme for booking (model.listing_quantity)
      { total_price: total, commission_total: calculate_commission(total, model.commission_from_seller, model.minimum_commission) }
    end
  end

  def calculate_commission(total_price, commission_from_seller, minimum_commission)
    if commission_from_seller.blank? || commission_from_seller == 0
      Money.new(0, minimum_commission.currency)
    else
      commission_by_percentage = total_price * (commission_from_seller / 100.0)
      (commission_by_percentage > minimum_commission) ? commission_by_percentage : minimum_commission
    end
  end
end
