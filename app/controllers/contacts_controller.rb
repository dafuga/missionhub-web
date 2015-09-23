require 'contact_actions'
class ContactsController < ApplicationController
  include ContactActions
  include ActionView::Helpers::DateHelper

  before_filter :get_person
  before_filter :ensure_current_org
  before_filter :authorize
  skip_before_filter :clear_advanced_search

  rescue_from OrganizationalPermission::InvalidPersonAttributesError do |exception|
    #render 'update_leader_error'
  end

  def set_labels
    people_ids = (params[:people_ids] || '').split(',')
    label_ids = (params[:label_ids] || '').split(',')
    remove_label_ids = params[:remove_label_ids] || ''
    unchanged_label_ids = params[:unchanged_label_ids] || ''
    remove_label_ids = remove_label_ids.split(',') - unchanged_label_ids.split(',')
    @from_all_contacts = params[:from_all_contacts]

    Retryable.retryable times: 5 do
      OrganizationalLabel.mass_update(label_ids, remove_label_ids, people_ids, current_organization, current_person)
    end

    if @from_all_contacts == "0"
      @person = current_organization.people.find_by(id: people_ids.first)
      @labels = @person.assigned_organizational_labels(current_organization.id).uniq if @person.present?
    end
    filter
  end

  def set_permissions
    @people = Person.where(id: params[:people_ids].split(','))
    @permission_id = params[:permission_id]

    @people.each do |person|
      current_organization.change_person_permission(person, @permission_id, current_person.id)
      @permissions = person.permissions_for_org_id(current_organization.id)
      @assigned_tos = person.assigned_to_people_by_org(current_organization)
    end

    if @people.count == 1
      @person = @people.first
    end
    filter
  end

  def bulk_update
    people_to_update = current_organization.all_people_with_archived.where("people.id IN (?)", params[:people_ids].split(","))

    if params[:leader_id].present? && people_to_update.present?
      if params[:leader_id].include?("0")
        people_to_update.each do |person|
          person.assigned_tos.where('contact_assignments.organization_id' => current_organization.id).delete_all
        end
      else
        params[:leader_id].each do |leader_id|
          if leader = current_organization.leaders.where(id: leader_id).try(:first)
            leader.assign_contacts(people_to_update.collect(&:id), current_organization, current_person)
          end
        end
      end
    end

    people_to_update.each do |person|
      if params[:group_id].present?
        group = current_organization.groups.find(params[:group_id])
        group_membership = group.group_memberships.where(person_id: person.id).first_or_initialize
        group_membership.save
      end

      update_org_permission_field = Hash.new
      org_permission = person.organizational_permission_for_org(current_organization)
      if org_permission.present?
        if params[:followup_status].present?
          update_org_permission_field[:followup_status] = params[:followup_status]
        end
        if params[:cru_status_id].present?
          update_org_permission_field[:cru_status_id] = params[:cru_status_id]
        end
        org_permission.update_attributes(update_org_permission_field) if update_org_permission_field.present?
      end

      update_person_fields = Hash.new
      if params[:student_status].present?
        update_person_fields[:student_status] = params[:student_status]
      end
      if params[:change_gender].present?
        update_person_fields[:gender] = params[:change_gender]
      end
      if params[:change_faculty].present?
        update_person_fields[:faculty] = params[:change_faculty]
      end
      person.update_attributes(update_person_fields) if update_person_fields.present?

    end if people_to_update.present?
    filter
  end

  def filter
    # Set per_page
    if params[:per_page].present?
      session[:per_page] = params[:per_page]
    elsif !session[:per_page].present?
      session[:per_page] = 25
    end

    # Set filters
    session[:filters] ||= {}
    if params[:filters] == "clear"
      session[:filters] = nil
      @saved_searches = current_user.saved_contact_searches.where('organization_id = ?', current_organization.id)
    else
      if params[:advanced_search].present? || params[:page].present?
        session[:filters] = params
      elsif params[:per_page].present?
        session[:per_page] = session[:per_page]
        session[:page] = 1
      elsif params[:search].present?
        session[:filters][:search] = params[:search]
        session[:page] = 1
      end
    end
    clean_params
    permissions_for_assign
    fetch_contacts
    @answers = generate_answers(@people, @organization, @questions, @survey_scope || @surveys)

    respond_to do |format|
      format.js
      format.html { redirect_to all_contacts_path }
    end
  end

  def clean_params(clean_all = false)
    params[:assigned_to] = 'all' unless params[:assigned_to].present?
    if params[:paginate] == "true"
      unless params[:page].present?
        session[:filters] ||= Hash.new
        session[:filters][:page] = 1
        params[:page] = 1
      end
    end

    if search? && clean_all
      session[:filters] = params
      redirect_to all_contacts_path
      true
    else
      session[:filters].each do |k, v|
        unless ['controller','action'].include?(k)
          params[k] = v
        end
      end if session[:filters].present?
      false
    end
  end

  def contacts_all
    session[:filters].each do |k, v|
      unless ['controller','action'].include?(k)
        params[k] = v
      end
    end if session[:filters].present?
    fetch_contacts(true)
    @filtered_people = @all_people - @people
  end

  def export_csv
    if params[:only_ids].present? && params[:format].present?
      if params[:only_ids].present?
        fetch_contacts(true)
        @all_people = @all_people.where('people.id IN (:ids)', ids: params[:only_ids].split(','))
        @roles = Hash[OrganizationalPermission.active.where(organization_id: @organization.id, person_id: @all_people.collect(&:id)).map {|r| [r.person_id, r] if r.permission_id == Permission::NO_PERMISSIONS_ID }]
        @all_answers = generate_answers(@all_people, @organization, @questions, @survey_scope || @surveys)
        @questions.select! { |q| !%w{first_name last_name phone_number email}.include?(q.attribute_name) }
        csv = ContactsCsvGenerator.generate(@roles, @all_answers, @questions, @all_people, @organization)
        send_data csv, filename: "#{@organization.to_s} - Contacts.csv", type: "text/csv; charset=utf-8; header=present"
      else
        redirect_to :back, notice: I18n.t('contacts.index.cannot_find_ids')
      end
    else
      redirect_to :back, notice: I18n.t('contacts.index.none_checked')
    end
  end

  def all_contacts
    session[:filters] = nil if params[:filters] == "clear"
    respond_to do |wants|
      wants.html do
        clean_params(true)
        # groups_for_assign
        # prepare_pagination
        labels_for_assign
        permissions_for_assign
        fetch_contacts

        @saved_searches = current_user.saved_contact_searches.where('organization_id = ?', current_organization.id)
        @answers = generate_answers(@people, @organization, @questions, @survey_scope || @surveys)
      end
    end
  end

  def update_advanced_search_surveys
    @filtered_surveys = current_organization.surveys.where(id: params[:survey_ids].split(",")).includes(:questions).order(:title)
    @remove_survey_ids = current_organization.surveys.pluck(:id) - @filtered_surveys.pluck(:id)
  end

  def my_contacts_all
    params[:status] = nil if params[:status] == 'all'
    params[:assigned_to] = current_person.id
    session[:filters] = params
    fetch_contacts(true)
    @filtered_people = @all_people.find_all{|person| !@people.include?(person) }
  end

  def my_contacts
    permissions_for_assign
    labels_for_assign

    params[:page] ||= 1
    url = request.url.split('?')
    @attr = url.size > 1 ? url[1] : ''

    params[:status] = nil if params[:status] == 'all'
    params[:assigned_to] = current_person.id
    session[:filters] = params

    fetch_contacts(false)

    if params[:include_archived].present? && params[:include_archived] == 'true'
      @assigned_contacts = @organization.assigned_contacts_with_archived_to([current_person])
    else
      @assigned_contacts = @organization.assigned_contacts_to([current_person])
    end
    if @assigned_contacts.present?
      @inprogress_contacts = @assigned_contacts.joins(:organizational_permissions).where("organizational_permissions.organization_id = ? AND organizational_permissions.followup_status <> 'completed'", current_organization.id)
      @completed_contacts = @assigned_contacts.joins(:organizational_permissions).where("organizational_permissions.organization_id = ? AND organizational_permissions.followup_status = 'completed'", current_organization.id)
    else
      @inprogress_contacts = []
      @completed_contacts = []
    end
    session[:filters] = nil
  end

  def index
    permissions_for_assign
    url = request.url.split('?')
    @attr = url.size > 1 ? url[1] : ''

    respond_to do |wants|
      wants.html do
        fetch_contacts(false)
        @answers = generate_answers(@people, @organization, @questions, @surveys)
      end

      wants.csv do
        fetch_contacts(true)
        @permissions = OrganizationalPermission.get_permission_hash(@organization, @all_people)
        # @permissions = Hash[OrganizationalPermission.active.where(organization_id: @organization.id, person_id: @all_people.collect(&:id)).map {|r| [r.person_id, r] if r.permission_id == Permission::NO_PERMISSIONS_ID }]
        @all_answers = generate_answers(@all_people, @organization, @questions, @surveys)
        @questions.select! { |q| !%w{first_name last_name phone_number email}.include?(q.attribute_name) }
        filename = @organization.to_s
        @all_people = @all_people.where('people.id IN (:ids)', ids: params[:only_ids].split(',')) if params[:only_ids].present?
        csv = ContactsCsvGenerator.generate(@permissions, @all_answers, @questions, @all_people, @organization)
        send_data(csv, :filename => "#{filename} - Contacts.csv", :type => 'application/csv' )
      end
    end
  end

  def search_by_name_and_email
    @people = params[:include_archived] ?
      current_organization.people.search_by_name_or_email(params[:term].strip, current_organization.id).uniq :
      current_organization.people.search_by_name_or_email(params[:term].strip, current_organization.id).uniq.archived_not_included
    respond_to do |format|
      format.json { render json: @people.collect{|person| {"label" => person.name, "email" => person.email.downcase, "id" => person.id}}.to_json }
    end
  end

  def auto_suggest_send_email
    term = params[:q].try(:strip).downcase

		# Search - enable "All contacts" for admins
		all_contacts = is_admin? && term =~ /all/ ? [{:name=>"All (#{current_organization.all_people.count})", :id=>"ALL-PEOPLE"}] : []

		# Search Permissions
		permissions = current_organization.permission_search(term)
		get_and_merge_unfiltered_people
		permissions_results = permissions.collect{|p| {name: "#{p.name} (#{@people_unfiltered.where("permission_id = ?", p.id).count})", id: "ROLE-#{p.id}"}}

    # Search Labels
    labels = current_organization.label_search(term)
    labels_results = labels.collect{|p| {name: "#{p.name} (#{p.label_contacts_from_org(current_organization).count})", id: "LABEL-#{p.id}"}}
    #To remove all labels if has 0 contact
    #labels_results = labels.collect{|p|
    #   count = p.label_contacts_from_org(current_organization).count
    #   count > 0 ? {name: "#{p.name} (#{count})", id: "LABEL-#{p.id}"} : nil
    #}.delete_if{|x| x == nil}

		# Search Groups
		groups = current_organization.group_search(term)
		groups_results = groups.collect{|p| {name: "#{p.name} (#{p.group_memberships.count})", id: "GROUP-#{p.id}"}}

		# Search People
		people = current_organization.people.email_search(term, current_organization.id).uniq
		people = people.archived_not_included unless params[:include_archived].present?
		people_results = people.collect{|p| {name: "#{p.name} - #{p.email.downcase}", id: p.id.to_s}}

		@results = all_contacts + permissions_results + labels_results + groups_results + people_results

		respond_to do |format|
		  format.json { render json: @results.to_json }
		end
  end

  def auto_suggest_send_text
    term = params[:q].try(:strip).downcase

		# Search - enable "All contacts" for admins
		all_contacts = is_admin? && term =~ /all/ ? [{:name=>"All (#{current_organization.all_people.count})", :id=>"ALL-PEOPLE"}] : []

		# Search Permissions
		permissions = current_organization.permission_search(term)
		get_and_merge_unfiltered_people
		permissions_results = permissions.collect{|p| {name: "#{p.name} (#{@people_unfiltered.where("permission_id = ?", p.id).count})", id: "ROLE-#{p.id}"}}

    # Search Labels
    labels = current_organization.label_search(term)
    labels_results = labels.collect{|p| {name: "#{p.name} (#{p.label_contacts_from_org(current_organization).count})", id: "LABEL-#{p.id}"}}

		# Search Groups
		groups = current_organization.group_search(term)
		groups_results = groups.collect{|p| {name: "#{p.name} (#{p.group_memberships.count})", id: "GROUP-#{p.id}"}}

		# Search People
    people = current_organization.people.phone_search(term, current_organization.id).uniq
    people = people.archived_not_included unless params[:include_archived].present?
		people_results = people.collect{|p| {name: "#{p.name} - #{p.pretty_text_phone_number}", id: p.id.to_s}}

		@results = all_contacts + permissions_results + labels_results + groups_results + people_results
		respond_to do |format|
		  format.json { render json: @results.to_json }
		end
  end

  def add_contact_check_email
    @email = params[:email]
    if @email.present?
      @person_ids = EmailAddress.where("email LIKE ?", "%#{@email}%").group("person_id").collect(&:person_id)
      @people = Person.where("id IN (?)", @person_ids)
      @people = @people.reject do |person|
        person if person.organizational_permissions.find_by(organization_id: current_organization.id).present?
      end
    end
  end

  def mine
    permissions_for_assign
    params[:status] ||= 'in_progress'
    url = request.url.split('?')
    @attr = url.size > 1 ? url[1] : ''
    @organization = current_organization
    fetch_mine

    @all_contacts = @all_people
    @inprogress_contacts = @all_people.where("organizational_permissions.followup_status <> 'completed'")
    @completed_contacts = @all_people.where("organizational_permissions.followup_status = 'completed'")
    if params[:status] == 'completed'
      @all_people = @completed_contacts
    elsif params[:status] == 'in_progress'
      @all_people = @inprogress_contacts
    end

    @q = @all_people.where('1 <> 1').search(params[:q])

    order = params[:q].present? ? params[:q][:s] : "people.last_name ASC, people.first_name ASC";
	  @all_people = @all_people.order("#{order}")
    @people = @all_people.select("DISTINCT(people.id), people.*").page(params[:page])
  end

  def mine_all
    mine
    @filtered_people = @all_people.find_all{|person| !@people.include?(person) }
    render :partial => 'contacts/mine_all'
  end

  def update
    @person = Person.find(params[:id])
    authorize!(:update, @person)

    @person.update_attributes(params[:person]) if params[:person]

    # birth_date validation
    @valid_date = true
    if params[:answers]
      params[:answers].each do |survey,answers|
        answers.each do |key,val|
          if val.present? && date_question = Element.where(id: key.to_i).first
            @person.birth_date = val if date_question.attribute_name == 'birth_date'
            @person.graduation_date = val if date_question.attribute_name == 'graduation_date'
            @person.save if ['birth_date','graduation_date'].include?(date_question.attribute_name)
            unless @person.valid?
              @valid_date = false
              break
            end
          end
        end
      end if @valid_date
    end
    update_survey_answers if params[:answers]
    @person.update_date_attributes_updated

    unless @valid_date
      redirect_to edit_survey_response_path(@person), notice: @person.errors.full_messages.first
    else
      if @person.valid? && (!@answer_sheet || @answer_sheet.valid_person?)
        params[:update] = 'true'
      end
      respond_to do |wants|
        wants.js
        wants.html { redirect_to survey_response_path(@person) }
        wants.mobile { redirect_to survey_response_path(@person) }
      end
    end
  end

  def show
    redirect_to profile_path(params[:id])
  end

  def edit
    redirect_to survey_response_path(params[:id])
  end

  def create
    permissions_for_assign
    params[:answers].each do |answer|
      answers = []
      fields = answer[1]
      if fields.is_a?(Hash)
        # Read birth_date question from non-predefined survey
        answers.each do |key,val|
          if val.present? && date_question = Element.where(id: key.to_i).first
            @person.birth_date = val if date_question.attribute_name == 'birth_date'
            @person.graduation_date = val if date_question.attribute_name == 'graduation_date'
            break unless @person.valid?
          end
        end
      else
        # Read birth_date question from predefined survey
        question_id = answers[0]
        if fields.present? && date_question = Element.where(id: question_id.to_i).first
          @person.birth_date = fields if date_question.attribute_name == 'birth_date'
          @person.graduation_date = fields if date_question.attribute_name == 'graduation_date'
          break unless @person.valid?
        end
      end
    end if params[:answers]

    @organization = current_organization
    create_contact

  end

  def destroy
    contact = Person.find(params[:id])
    authorize! :manage, contact
    current_organization.remove_person(contact)

    render :nothing => true
  end

  def bulk_destroy
    authorize! :manage, current_organization
    Person.find(params[:ids]).each do |contact|
      current_organization.remove_person(contact)
    end

    render :nothing => true
  end

  def send_reminder
    to_ids = params[:to].split(',')
    users = current_organization.users.where(id: to_ids)

    if users.present?
      ContactsMailer.delay.reminder(users.collect(&:email).compact, current_person.email, params[:subject], params[:body])
    end
    render nothing: true
  end

  def show_assign_search

  end

  def show_hidden_questions
    @organization = current_organization
    @all_questions = @organization.questions
    @predefined_survey = Survey.find(ENV.fetch('PREDEFINED_SURVEY'))
    excepted_predefined_fields = ['first_name','last_name','gender','phone_number']
    @predefined_questions = current_organization.predefined_survey_questions.where("attribute_name NOT IN (?)", excepted_predefined_fields)
    @questions = (@all_questions.where("survey_elements.hidden" => false) + @predefined_questions.where(id: current_organization.settings[:visible_predefined_questions])).uniq
    @hidden_questions = ((@predefined_questions + @all_questions) - @questions).flatten.uniq
  end

  def hide_question_column
  	@selected_survey_id = params[:survey_id].to_i
  	@selected_question_id = params[:question_id]

  	if @selected_question_id == "visible_surveys_column"
      current_organization.settings[:visible_surveys_column] = false
      current_organization.save(validate: false)
  	else
    	@selected_question_id = @selected_question_id.to_i
		  @predefined_questions = current_organization.predefined_survey_questions
		  if @predefined_questions.collect(&:id).include?(@selected_question_id)
		    @question = @predefined_questions.find(@selected_question_id)
		    @organization = current_organization
		    @organization.survey_elements.each do |pe|
		      pe.update_attribute(:hidden, true) if pe.element_id == @question.id
		    end
		    if current_organization.settings[:visible_predefined_questions].present?
		      current_organization.settings[:visible_predefined_questions] = current_organization.settings[:visible_predefined_questions].reject {|x| x == @question.id}
		      current_organization.save(validate: false)
		    end
		  else
		    @survey = Survey.find(@selected_survey_id)
		    @question = Element.find(@selected_question_id)
		    @organization = @survey.organization
		    @organization.survey_elements.each do |pe|
		      pe.update_attribute(:hidden, true) if pe.element_id == @question.id
		    end
		  end
		end
    render nothing: true
  end

  def unhide_questions
    @predefined_questions = current_organization.predefined_survey_questions
    @selected_question_ids = params[:question_ids].split(",")

    @selected_question_ids.each do |question_id|
      if question_id == "visible_surveys_column"
        current_organization.settings[:visible_surveys_column] = true
        current_organization.save!
      else
        question_id = question_id.to_i
        if @predefined_questions.collect(&:id).include?(question_id)
    	    if @question = @predefined_questions.find(question_id)
            settings = current_organization.settings
            if settings[:visible_predefined_questions].nil?
              settings[:visible_predefined_questions] = Array.new
            end
            settings[:visible_predefined_questions] << @question.id
            current_organization.save(validate: false)
          end
        else
          if survey_element = current_organization.survey_elements.where(element_id: question_id).first
            survey_element.update_attributes(hidden: false)
            @question = survey_element.element
          end
        end
      end
    end
  end

  def unhide_question_column
  	@selected_survey_id = params[:survey_id].to_i
  	@selected_question_id = params[:question_id]

  	if @selected_question_id == "visible_surveys_column"
      current_organization.settings[:visible_surveys_column] = true
      current_organization.save!
  	else
    	@selected_question_id = @selected_question_id.to_i
		  @predefined_questions = current_organization.predefined_survey_questions
		  if @predefined_questions.collect(&:id).include?(@selected_question_id)
		    @question = @predefined_questions.find(@selected_question_id)
		    @organization = current_organization
		    @survey = @predefined_survey

        settings = current_organization.settings
        settings[:visible_predefined_questions] = Array.new if settings[:visible_predefined_questions].nil?
        settings[:visible_predefined_questions] << @question.id
        current_organization.save(validate: false)
      else
        @survey = Survey.find(params[:survey_id])
        @organization = @survey.organization
        @survey_element = @organization.survey_elements.where(element_id: @selected_question_id).first
        @survey_element.update_attribute(:hidden, false)
        @question = @survey_element.element
      end
    end
    respond_to do |wants|
      wants.html { redirect_to :back }
      wants.js
    end
  end

  def show_search_hidden_questions
    show_hidden_questions
    @search_hidden_questions = @hidden_questions
  end

  def display_sidebar
    @organization = current_organization
    # Saved Search
    @all_saved_contact_searches = current_user.saved_contact_searches.where('organization_id = ?', current_organization.id)
    get_and_merge_unfiltered_people
  end

  def display_new_sidebar
    @organization = current_organization
    # Saved Search
    @all_saved_contact_searches = current_user.saved_contact_searches.where('organization_id = ?', current_organization.id)

    get_and_merge_unfiltered_people
  end

  def search_locate_contact
    firstname = params[:fname]
    lastname = params[:lname]
    email = params[:email]
    @manage_org_ids = current_person.organizational_permissions.find_admin_or_leader
    if @manage_org_ids
      get_all_people = Person.where('organizational_permissions.organization_id IN (?)', @manage_org_ids.collect(&:organization_id)).joins(:organizational_permissions).uniq
      if get_all_people.count > 0
        query = ""
        if firstname.present?
          query += " first_name LIKE \"#{manage_wild_card(firstname.strip)}\" "
        end
        if lastname.present?
          query += " AND " if query.length > 0
          query += " last_name LIKE \"#{manage_wild_card(lastname.strip)}\" "
        end
        if email.present?
          query += " AND " if query.length > 0
          query += " email LIKE \"#{manage_wild_card(email.strip)}\" "
        end
        @filtered_contact = get_all_people.joins(:email_addresses).where(query) if query.length > 0
      end
    end
  end

  protected

    def prepare_pagination
      params[:page] ||= 1
      if params[:per_page].present?
        session[:per_page] = params[:per_page].to_i
      else
        unless session[:per_page].present?
          session[:per_page] ||= 25
        end
      end
    end

    def initialize_variables
      # Layout
      @header = nil
      @style = params[:edit] ? 'display:block' : 'display:none'

      # Organization
      @organization = Organization.includes(:surveys, :groups, :questions).find(current_organization.id)

      # Saved Search
      @saved_contact_search = current_user.saved_contact_searches.where("full_path = '#{convert_hash_to_url(session[:filters])}'").first || SavedContactSearch.new

      # Surveys & Questions
      initialize_surveys_and_questions

      # Labels
      @people_for_labels = Person.people_for_labels(current_organization)
    end

    def fetch_contacts(load_all = false)
      # Load Saved Searches, Surveys & Questions
      initialize_variables
      # update_fb_friends if current_person.friends.count == 0

      # Fix old search variable from saved searches
      handle_old_search_variable if params[:search] == "1"

      # Get people
      build_people_scope

      # Filter results
      if params[:label].present?
        @people_scope = Person.filter_by_label(@people_scope, @organization, params[:label], params[:label_filter])
      end

      if params[:group].present?
        @people_scope = Person.filter_by_group(@people_scope, @organization, params[:group], params[:group_filter])
      end

      if params[:permission].present?
        @people_scope = Person.filter_by_permission(@people_scope, @organization, params[:permission])
      end

      if params[:status].present?
        @people_scope = Person.filter_by_status(@people_scope, @organization, params[:status])
      end

      if params[:interaction_type].present?
        @people_scope = Person.filter_by_interaction(@people_scope, @organization, params[:interaction_type], params[:interaction_filter])
      end

      if params[:advanced_search].present?
        if params[:survey_scope].present?
          @survey_scope = Person.build_survey_scope(@organization, params[:survey_scope])
          @people_scope = Person.filter_by_survey_scope(@people_scope, @organization, @survey_scope)
        end
        @people_scope = filter_by_advanced_search(@people_scope)
      end

      filter_by_search if params[:do_search].present?

      # Sort & Limit Results
      sort_people(params[:page], load_all)
    end

    def update_fb_friends
      fb_auth = current_user.authentications.first
      current_person.update_friends(fb_auth) if fb_auth.present?
    end

    def build_people_scope
      assigned_to = params[:assigned_to].is_a?(Array) ? params[:assigned_to].first : params[:assigned_to]
      if params[:assigned_to].present?
        case assigned_to
        when 'all'
          if params[:include_archived].present? && params[:include_archived] == 'true'
            @people_scope = @organization.all_people_with_archived
          else
            @people_scope = @organization.all_people
          end
        when 'unassigned'
          if params[:include_archived].present? && params[:include_archived] == 'true'
            @people_scope = @organization.unassigned_contacts_with_archived
          else
            @people_scope = @organization.unassigned_contacts
          end
          @header = I18n.t('contacts.index.unassigned')
        when 'no_activity'
          @people_scope = @organization.no_activity_contacts
          @header = I18n.t('contacts.index.no_activity')
        when 'friends'
          @people_scope = current_person.contact_friends(@organization)
          @header = I18n.t('contacts.index.friend_responses')
        when *Rejoicable::OPTIONS
          @people_scope = @organization.send(:"#{params[:assigned_to]}_contacts")
          @header = I18n.t("rejoicables.#{params[:assigned_to]}")
        else
          unless params[:assigned_to].is_a?(Array)
            params[:assigned_to] = [params[:assigned_to]]
          end
          selected_leaders = @organization.leaders.where(id: params[:assigned_to])
          if selected_leaders.present?
            if params[:include_archived].present? && params[:include_archived] == 'true'
              @people_scope = @organization.assigned_contacts_with_archived_to(selected_leaders)
            else
              @people_scope = @organization.assigned_contacts_to(selected_leaders)
            end
            @header = I18n.t('contacts.index.responses_assigned_to', assigned_to: selected_leaders.to_sentence)
          end
          @people_scope ||= current_organization.all_people.where(id: 0)
        end
      elsif params[:dnc] == 'true'
        @people_scope = @organization.dnc_contacts
        @header = I18n.t('contacts.index.dnc')
      elsif params[:completed] == 'true'
        @header = I18n.t('contacts.index.completed')
        @people_scope = @organization.completed_contacts
      elsif params[:archived] == 'true'
        @header = I18n.t('contacts.index.archived')
        @people_scope = @organization.all_archived_people
      elsif params[:filter_label].present?
        if filter_label = Label.find(params[:filter_label])
          if params[:include_archived_labels].present? && params[:include_archived_labels] == 'true'
            @people_scope = filter_label.label_contacts_from_org_with_archived(@organization)
          else
            @people_scope = filter_label.label_contacts_from_org(@organization)
          end
        end
      end
      @people_scope ||= current_organization.all_people.includes(:primary_phone_number, :primary_email_address)
      if params[:friends_only] == 'true'
        @people_scope = @people_scope.where("people.id IN (?)", current_person.friends.collect(&:id))
      end
      return @people_scope
    end

    def get_and_merge_unfiltered_people
      x = []
      org_ids = params[:subs] == 'true' ? current_organization.self_and_children_ids : current_organization.id
      @people_unfiltered = Person.where('organizational_permissions.organization_id' => org_ids)
                                 .where("organizational_permissions.followup_status <> 'do_not_contact' OR organizational_permissions.followup_status IS NULL")
                                 .joins(:organizational_permissions_including_archived)

      if params[:include_archived].blank? && params[:archived].blank?
        @people_unfiltered = @people_unfiltered.where('organizational_permissions.archive_date' => nil, 'organizational_permissions.deleted_at' => nil)
      end
      @people_scope = @people_scope.merge(@people_unfiltered) if @people_scope.present?
    end

    def filter_archived_only
      @header = I18n.t('contacts.index.archived')
      @people_scope = @people_scope.where(id: current_organization.all_archived_people.collect(&:id))
    end

    def handle_old_search_variable
      params[:search] = nil
      params[:do_search] = "1"
    end

    def filter_by_mine
      @inprogress_contacts = @people_scope.where("organizational_permissions.followup_status <> 'completed'")
      @completed_contacts = @people_scope.where("organizational_permissions.followup_status = 'completed'")

      if params[:status] == 'completed'
        @people_scope = @completed_contacts
      elsif params[:status] == 'in_progress'
        @people_scope = @inprogress_contacts
      end
    end

    def filter_by_advanced_search(people)
      people = Person.where(id: people.collect(&:id))
      @header = I18n.t('dialogs.advanced_search.header')
      if params[:search_any].present?
        key = "%#{params[:search_any].downcase.strip}%"
        people = people
          .joins("LEFT OUTER JOIN email_addresses ON people.id = email_addresses.person_id")
          .joins("LEFT OUTER JOIN phone_numbers ON people.id = phone_numbers.person_id")
          .where("people.last_name LIKE :key OR people.first_name LIKE :key OR email_addresses.email LIKE :key OR phone_numbers.number LIKE :key", key: key)
      end

      if params[:gender].present?
        people = Person.filter_by_gender(people, current_organization, params[:gender])
      end

      if params[:assignment].present?
        params[:assignment] = params[:assignment].is_a?(Array) ? params[:assignment] : [params[:assignment]]
        if params[:assignment].count == 1
          if params[:assignment].first == "1"
            assigned_people_ids = current_organization.assigned_contacts.collect(&:id).uniq
            people = people.where("people.id IN (?)", assigned_people_ids)
          elsif params[:assignment].first == "0"
            unassigned_people_ids = current_organization.unassigned_contacts.collect(&:id).uniq
            people = people.where("people.id IN (?)", unassigned_people_ids)
          end
        end
      end

      if params[:faculty].present?
        people = Person.filter_by_faculty(people, current_organization, params[:faculty])
      end

      survey_answers = params[:survey_answer]
      if params[:survey_answer_option].present? && params[:survey_scope].present? && survey_answers.present?
        survey_ids = survey_answers.keys
        if survey_ids.present?
          surveys = current_organization.surveys.where(id: survey_ids)
          surveys.each do |survey|
            if questions = params[:survey_answer_option][survey.id.to_s]
              questions.each do |question_id, option|
                element = Element.find(question_id)
                if element.kind == "TextField"

                  answer = ""
                  begin
                    answer = params[:survey_answer][survey.id.to_s][question_id]
                  rescue; end
                  people = Person.filter_by_text_field_answer(people, current_organization, survey, element, answer, option, params[:survey_range_toggle], params[:survey_range])

                elsif element.kind == "ChoiceField"

                  answer = Hash.new
                  begin
                    answer = params[:survey_answer][survey.id.to_s][question_id]
                  rescue; end
                  people = Person.filter_by_choice_field_answer(people, current_organization, survey, element, answer, option, params[:survey_range_toggle], params[:survey_range])

                elsif element.kind == "DateField"

                  answer = Hash.new
                  begin
                    answer = params[:survey_answer][survey.id.to_s][question_id]
                  rescue; end

                  if answer['start_day'].present? && answer['start_month'].present? && answer['start_year'].present?
                    answer["start"] = "#{answer['start_year']}-#{'%02d' % answer['start_month'].to_i}-#{'%02d' % answer['start_day'].to_i}"
                  else
                    answer["start"] = ""
                  end
                  if answer['end_day'].present? && answer['end_month'].present? && answer['end_year'].present?
                    answer["end"] = "#{answer['end_year']}-#{'%02d' % answer['end_month'].to_i}-#{'%02d' % answer['end_day'].to_i}"
                  else
                    answer["end"] = ""
                  end
                  params[:survey_answer][survey.id.to_s][question_id.to_s]['start'] = answer["start"]
                  params[:survey_answer][survey.id.to_s][question_id.to_s]['end'] = answer["end"]

                  people = Person.filter_by_date_field_answer(people, current_organization, survey, element, answer, option, params[:survey_range_toggle], params[:survey_range])

                end
              end
            end
          end
        end
      end
      return people
    end

    def filter_by_search
      @header = I18n.t('contacts.index.matching_seach')
      if params[:survey].present?
        @people_scope = @people_scope.includes(:answer_sheets).where("answer_sheets.survey_id" => params[:survey]).references(:answer_sheets)
      end
	    if params[:survey_updated_from].present? && params[:survey_updated_to].present?
	      @people_scope = @people_scope.find_by_survey_updated_by_daterange(format_date_for_search(params[:survey_updated_from]), format_date_for_search(params[:survey_updated_to]), current_organization.id)
	    end
      if params[:first_name].present?
        v = params[:first_name].strip
        term = (v.first == v.last && v.last == '"') ? v[1..-2] : "%#{v}%"
        @people_scope = @people_scope.where("first_name like ?", term)
      end
      if params[:last_name].present?
        v = params[:last_name].strip
        term = (v.first == v.last && v.last == '"') ? v[1..-2] : "%#{v}%"
        @people_scope = @people_scope.where("last_name like ?", term)
      end
      if params[:email].present?
        v = params[:email].strip
        term = (v.first == v.last && v.last == '"') ? v[1..-2] : "%#{v}%"
        @people_scope = @people_scope.joins(:email_addresses).where("email_addresses.email like ?", term)
      end
      if params[:group_name].present?
        v = params[:group_name].strip
        groups = current_organization.groups.where("name LIKE ?", "%#{v}%")
        people_ids = GroupMembership.where(group_id: groups.collect(&:id)).collect(&:person_id)
        @people_scope = @people_scope.where("people.id" => people_ids)
      end
      if params[:phone_number].present?
        v = PhoneNumber.strip_us_country_code(params[:phone_number])
        term = (v.first == v.last && v.last == '"') ? v[1..-2] : "%#{v}%"
        @people_scope = @people_scope.joins(:phone_numbers).where("phone_numbers.number like ?", term)
      end
      if params[:gender].present?
        @people_scope = @people_scope.where("gender = ?", params[:gender].strip)
      end
      if params[:assignment].present?
        if params[:assignment] == "Assigned"
          assigned_people_ids = current_organization.assigned_contacts.collect(&:id).uniq
          @people_scope = @people_scope.where("people.id IN (?)", assigned_people_ids)
        elsif params[:assignment] == "Unassigned"
          unassigned_people_ids = current_organization.unassigned_contacts.collect(&:id).uniq
          @people_scope = @people_scope.where("people.id IN (?)", unassigned_people_ids)
        end
      end
      if params[:nationality].present?
        @people_scope = @people_scope.where("nationality = ?", params[:nationality].strip)
      end
      if params[:faculty].present?
        @people_scope = @people_scope.where("faculty = ?", params[:faculty].strip)
      end
      if params[:status].present?
        @people_scope = @people_scope.where("organizational_permissions.followup_status" => params[:status].strip)
      end
      if params[:answers].present?
        params[:answers].each do |q_id, v|
          question = Element.find(q_id)
          if v.is_a?(String)
            if question.is_a?(TextField)
              # do an exact search if the term is wrapped with quotes
              term = (v.first == v.last && v.last == '"') ? v[1..-2] : "%#{v}%"
            else
              term = v
            end

						if term =~ /^([1-9]|0[1-9]|1[012])\/([1-9]|0[1-9]|[12][1-9]|3[01])\/(19|2\d)\d\d$/
							begin
								get_date = term.split('/')
								term = Date.parse("#{get_date[2]}-#{get_date[0]}-#{get_date[1]}").strftime("%Y-%m-%d")
							rescue
							end
						end

            # If this question is assigned to a column, we need to handle that differently
            if question.object_name.present?
              table_name = case question.object_name
              when 'person'
                case question.attribute_name
                when 'email'
                  @people_scope = @people_scope.joins(:email_addresses).where("#{EmailAddress.table_name}.email like ?", term) unless v.strip.blank?
                when 'phone_number'
                  @people_scope = @people_scope.joins(:phone_numbers).where("#{PhoneNumber.table_name}.number like ?", term) unless v.strip.blank?
                when 'address1', 'city', 'state', 'country', 'dorm', 'room', 'zip'
                  @people_scope = @people_scope.joins(:current_address).where("#{Address.table_name}.#{question.attribute_name} like ?", term) unless v.strip.blank?
                when 'graduation_date'
                	table = "#{Person.table_name}.#{question.attribute_name}"
	              	where_query = term =~ /^\d{4}$/ ? "YEAR(#{table})" : table
									@people_scope = @people_scope.where("#{where_query} like ?", term) unless v.strip.blank?
                else
									@people_scope = @people_scope.where("#{Person.table_name}.#{question.attribute_name} like ?", term) unless v.strip.blank?
                end
              end
            else
              unless v.strip.blank?
                @people_scope = @people_scope.joins(:answer_sheets)
                @people_scope = @people_scope.joins("INNER JOIN `answers` as a#{q_id} ON a#{q_id}.`answer_sheet_id` = `answer_sheets`.`id`").where("a#{q_id}.question_id = ? AND a#{q_id}.value like ?", q_id, term)
              end
            end
          else
            conditions = ["#{Answer.table_name}.question_id = ?", q_id]
            answers_conditions = []
            v.each do |k1, v1|
              unless v1.strip.blank?
                if question.is_a?(TextField)
                  answers_conditions << "#{Answer.table_name}.value like ?"
                  conditions << (v1.first == v1.last && v1.last == '"') ? v1[1..-2] : "%#{v1}%"
                else
                  answers_conditions << "#{Answer.table_name}.value = ?"
                  conditions << v1
                end
              end
            end
            if answers_conditions.present?
              conditions[0] = conditions[0] + ' AND (' + answers_conditions.join(' OR ') + ')'
              @people_scope = @people_scope.joins(:answer_sheets => :answers).where(conditions)
            end
          end
        end
      end
      if params[:search_type].present? && params[:search_type] == "basic"
        @people_scope = @people_scope.search_by_name_or_email(params[:query], current_organization.id)
      end
    end

    def sort_people(page = 1, fetch_all = false)
      @q = Person.where('1 <> 1').search(nil) # Fake a search object for sorting
      @all_people = Person.includes(:primary_email_address, :primary_phone_number, :labels).where("people.id IN (?)", @people_scope.collect(&:id)).select("DISTINCT(people.id), people.*")

      if params[:search].present?
        sort_query = params[:search][:meta_sort].gsub('.asc',' asc').gsub('.desc',' desc')
        if sort_query.include?('last_survey')
          @all_people = @all_people.get_and_order_by_latest_answer_sheet_answered(sort_query, current_organization.id)
        end
        if sort_query.include?('labels')
          @all_people = @all_people.get_and_order_by_label(sort_query, current_organization.id)
        end
        if sort_query.include?('followup_status')
          @all_people = @all_people.order_by_followup_status(current_organization, sort_query)
        end
        if sort_query.include?('phone_number')
          @all_people = @all_people.order_by_primary_phone_number(sort_query)
        end
        if sort_query.include?('email')
          @all_people = @all_people.order_by_primary_email_address(sort_query)
        end
        if ['dorm','zip','country','room','state','address1','city'].include?(sort_query.split(" ").first)
          sort_words = sort_query.split(" ")
          new_sort_query = "TRIM(addresses.#{sort_words[0]}) #{sort_words[1]}".strip if sort_words.count >= 1
          @all_people = @all_people.order_by_address_column(new_sort_query)
        end
        if ['last_name','first_name','gender'].any?{ |i| sort_query.include?(i) }
          order_query = sort_query.gsub('first_name', 'people.first_name')
                                  .gsub('last_name', 'people.last_name')
                                  .gsub('gender','ISNULL(people.gender), people.gender')
        end
        if Person.column_names.include?(sort_query.split(" ").first)
          sort_words = sort_query.split(" ")
          new_sort_query = "TRIM(#{sort_words[0]}) #{sort_words[1]}".strip if sort_words.count >= 1
          @all_people = @all_people.order_by_any_column(new_sort_query)
        end
      else
        order_query = "people.last_name asc, people.first_name asc"
      end
      @all_people = @all_people.select("DISTINCT(people.id), people.*").order(order_query)

      if fetch_all
        if params[:include_archived] || params[:archived]
          all_permissions = OrganizationalPermission.where(organization_id: current_organization.id, archive_date: nil, deleted_at: nil)
        else
          all_permissions = OrganizationalPermission.where(organization_id: current_organization.id).where("organizational_permissions.archive_date IS NOT NULL AND organizational_permissions.deleted_at IS NULL")
        end
        all_permissions = ActiveRecord::Base.connection.select_all(all_permissions.select('GROUP_CONCAT(permission_id) as permission_ids, person_id').group(:person_id))
        @permissions_by_person_id = {}
        all_permissions.each {|p| @permissions_by_person_id[p['person_id']] = p['permission_ids']}
      end
      @people = @all_people.page(page).per(session[:per_page])
    end

    def fetch_mine
      @all_people = Person.references(:assigned_tos, :organizational_permissions)
                        .includes(:assigned_tos, :organizational_permissions)
                        .where('contact_assignments.organization_id': current_organization.id,
                               'organizational_permissions.organization_id': current_organization.id,
                               'contact_assignments.assigned_to_id': current_person.id,
                               'organizational_permissions.permission_id': Permission::NO_PERMISSIONS_ID).uniq
    end

    def get_person
      @person = user_signed_in? ? current_user.person : Person.new
    end

    def authorize
      authorize! :manage_contacts, current_organization
    end

    def generate_answers(people, organization, questions, surveys = nil)
      answers = {}
      people_ids = people.pluck('people.id')
      survey_ids = surveys.present? ? surveys.collect(&:id) : organization.survey_ids
      people_ids.each do |id|
        answers[id] = {}
      end
      @surveys = {}
      AnswerSheet.where(survey_id: survey_ids, person_id: people_ids).includes(:survey, :answers, {:person => :primary_email_address}).each do |answer_sheet|
        @surveys[answer_sheet.person_id] ||= {}
        @surveys[answer_sheet.person_id][answer_sheet.survey] = answer_sheet.completed_at

        answers[answer_sheet.person_id] ||= {}
        questions.each do |q|
          answers[answer_sheet.person_id][q.id] = [q.display_response(answer_sheet), answer_sheet.updated_at] if q.display_response(answer_sheet).present?# or (q.attribute_name == "email" and q.object_name ==
        end
      end
      answers
    end
end
