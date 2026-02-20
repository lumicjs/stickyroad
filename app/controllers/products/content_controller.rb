# frozen_string_literal: true

class Products::ContentController < Products::BaseController
  def edit
    render inertia: "Products/Content/Edit", props: Products::ContentTabPresenter.new(product: @product, pundit_user:).props
  end

  def update
    should_publish = params[:publish].present? && !@product.published?
    should_unpublish = params[:unpublish].present? && @product.published?

    if should_unpublish
      return unpublish_and_redirect_to(edit_product_content_path(@product.unique_permalink))
    end

    ActiveRecord::Base.transaction do
      update_content_attributes
      publish! if should_publish
    end

    return if performed?

    check_offer_codes_validity

    if should_publish
      redirect_to edit_product_share_path(@product.unique_permalink), notice: "Published!", status: :see_other
    elsif permitted_redirect_path
      redirect_to permitted_redirect_path, notice: "Changes saved!", status: :see_other
    else
      redirect_back fallback_location: edit_product_content_path(@product.unique_permalink), notice: "Changes saved!", status: :see_other
    end
  rescue ActiveRecord::RecordNotSaved, ActiveRecord::RecordInvalid, Link::LinkInvalid => e
    error_message = if @product.errors.details[:custom_fields].present?
      "You must add titles to all of your inputs"
    else
      @product.errors.full_messages.first || e.message
    end
    redirect_to edit_product_content_path(@product.unique_permalink), alert: error_message
  rescue StandardError => e
    Bugsnag.notify(e)
    redirect_to edit_product_content_path(@product.unique_permalink), alert: "Something broke. We're looking into what happened. Sorry about this!"
  end

  private
    def update_content_attributes
      @product.assign_attributes(product_permitted_params.except(:files, :variants, :custom_domain, :rich_content))
      SaveFilesService.perform(@product, product_permitted_params, rich_content_params)
      update_rich_content
      Product::SavePostPurchaseCustomFieldsService.new(@product).perform
      @product.save!
      @product.is_licensed = @product.has_embedded_license_key?
      @product.is_multiseat_license = false unless @product.is_licensed
      @product.save! if @product.changed?
      @product.generate_product_files_archives!
    end

    def update_rich_content
      # Handle product-level rich content (shared content)
      update_rich_content_for_entity(@product, product_permitted_params[:rich_content] || [])

      # Handle variant-level rich content (per-variant content)
      (product_permitted_params[:variants] || []).each do |variant_params|
        variant = @product.alive_variants.find { |v| v.external_id == variant_params[:id] }
        next unless variant

        update_rich_content_for_entity(variant, variant_params[:rich_content] || [])
        variant.update_product_files_from_rich_content
      end
    end

    def update_rich_content_for_entity(entity, rich_content_params)
      existing_rich_contents = entity.alive_rich_contents.to_a
      rich_contents_to_keep = []

      rich_content_params.each.with_index do |content_params, index|
        rc = existing_rich_contents.find { |c| c.external_id == content_params[:id] } || entity.alive_rich_contents.build
        description = extract_rich_content_description(content_params[:description])
        processed_description = SaveContentUpsellsService.new(
          seller: @product.user,
          content: description,
          old_content: rc.description || []
        ).from_rich_content
        rc.update!(title: content_params[:title].presence, description: processed_description.presence || [], position: index)
        rich_contents_to_keep << rc
      end

      (existing_rich_contents - rich_contents_to_keep).each(&:mark_deleted!)
    end

    def rich_content_params
      rich_content = product_permitted_params[:rich_content] || []
      rich_content_params = [*rich_content]
      product_permitted_params[:variants]&.each { rich_content_params.push(*_1[:rich_content]) }
      rich_content_params.flat_map { _1.dig(:description, :content) }
    end

    def product_permitted_params
      @product_permitted_params ||= params.require(:product).permit(policy(@product).content_tab_permitted_attributes)
    end
end
