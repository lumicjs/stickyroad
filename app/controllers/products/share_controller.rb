# frozen_string_literal: true

class Products::ShareController < Products::BaseController
  before_action :ensure_published_for_share, only: [:edit]

  def edit
    render inertia: "Products/Share/Edit", props: Products::ShareTabPresenter.new(product: @product, pundit_user:).props
  end

  def update
    should_unpublish = params[:unpublish].present? && @product.published?

    if should_unpublish
      ActiveRecord::Base.transaction do
        update_share_attributes
      end
      return unpublish_and_redirect_to(edit_product_content_path(@product.unique_permalink))
    end

    ActiveRecord::Base.transaction do
      update_share_attributes
    end

    check_offer_codes_validity

    if permitted_redirect_path
      redirect_to permitted_redirect_path, notice: "Changes saved!", status: :see_other
    else
      redirect_back fallback_location: edit_product_share_path(@product.unique_permalink), notice: "Changes saved!", status: :see_other
    end
  rescue ActiveRecord::RecordNotSaved, ActiveRecord::RecordInvalid, Link::LinkInvalid => e
    error_message = @product.errors.full_messages.first || e.message
    redirect_to edit_product_share_path(@product.unique_permalink), alert: error_message
  rescue StandardError => e
    Bugsnag.notify(e)
    redirect_to edit_product_share_path(@product.unique_permalink), alert: "Something broke. We're looking into what happened. Sorry about this!"
  end

  private
    def ensure_published_for_share
      return if !@product.draft && @product.alive?

      redirect_path = @product.native_type == Link::NATIVE_TYPE_COFFEE ? edit_product_product_path(@product.unique_permalink) : edit_product_content_path(@product.unique_permalink)
      redirect_to redirect_path, alert: "Not yet! You've got to publish your awesome product before you can share it with your audience and the world."
    end

    def update_share_attributes
      @product.assign_attributes(product_permitted_params.except(:tags, :section_ids, :custom_domain))
      @product.save_tags!(product_permitted_params[:tags] || [])
      @product.show_in_sections!(product_permitted_params[:section_ids] || [])
      update_custom_domain if product_permitted_params.key?(:custom_domain)
      @product.save!
    end

    def product_permitted_params
      params.fetch(:product, {}).permit(policy(@product).share_tab_permitted_attributes)
    end
end
