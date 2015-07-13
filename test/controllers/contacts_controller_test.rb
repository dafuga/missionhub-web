require 'test_helper'

class ContactsControllerTest < ActionController::TestCase
  setup do
    stub_request(:get, /https:\/\/graph.facebook.com\/.*/).
      with(:headers => {'Accept'=>'*/*; q=0.5, application/xml', 'Accept-Encoding'=>'gzip, deflate', 'User-Agent'=>'Ruby'}).
      to_return(:status => 200, :body => "", :headers => {})
  end

  context "Before logging in" do
    should "redirect on update" do
      @contact = FactoryGirl.create(:person)
      put :update, id: @contact.id
      assert_redirected_to '/users/sign_in'
    end
  end

  context "hide & unhide question column" do
    setup do
      @user, org = admin_user_login_with_org
      @survey = FactoryGirl.create(:survey, organization: org) #create survey
      @question = FactoryGirl.create(:some_question)
      @survey.questions << @question

      @predefined = FactoryGirl.create(:survey, organization: org)
      ENV['PREDEFINED_SURVEY'] = @predefined.id.to_s
      @predefined.questions << FactoryGirl.create(:year_in_school_element)
    end

    should "hide the column" do
      xhr :post, :hide_question_column, {:survey_id => @survey.id, :question_id => @question.id}
      assert_response :success
    end

    should "unhide the column" do
      request.env["HTTP_REFERER"] = "localhost:3000"
      @question.update_attributes({:hidden => true})
      xhr :post, :unhide_question_column, {:survey_id => @survey.id, :question_id => @question.id}
      assert_response :success
    end
  end

  context "Advanced Search - " do
    setup do
      @user = FactoryGirl.create(:user_with_auxs)
      @person = @user.person
      sign_in @user

      @org = FactoryGirl.create(:organization)
      @org.add_admin(@person)
      @request.session[:current_organization_id] = @org.id

      @contact1 = FactoryGirl.create(:person, first_name: "abc", last_name: "qrs")
      FactoryGirl.create(:email_address, email: 'contact1@email.com', person: @contact1)
      @org.add_contact(@contact1)

      @contact2 = FactoryGirl.create(:person, first_name: "bcd", last_name: "rst")
      FactoryGirl.create(:email_address, email: 'contact2@email.com', person: @contact2)
      FactoryGirl.create(:phone_number, person: @contact2, number: "1111122222", primary: true)
      @org.add_contact(@contact2)

      @contact3 = FactoryGirl.create(:person, first_name: "cde", last_name: "stu")
      FactoryGirl.create(:phone_number, person: @contact3, number: "2222233333", primary: true)
      @org.add_contact(@contact3)

      @assignment1 = FactoryGirl.create(:contact_assignment, organization: @org, person: @contact1, assigned_to: @person)

      @predefined_survey = FactoryGirl.create(:survey, organization: @org)
      ENV['PREDEFINED_SURVEY'] = @predefined_survey.id.to_s
      @predefined_survey.questions << FactoryGirl.create(:year_in_school_element)
    end

    context "combined filters" do
      setup do
        @interaction_type1 = FactoryGirl.create(:interaction_type, organization_id: 0, i18n: "Interaction 1")
        FactoryGirl.create(:interaction, receiver: @contact1, creator: @person, organization: @org, interaction_type_id: @interaction_type1.id)
      end
      should "search status, interaction, and assigned_to" do
        xhr :get, :filter, {advanced_search: 1, search_any: "", assigned_to: [@person.id], interaction_filter: "any", interaction_type: [@interaction_type1.id], label_filter: "any", group_filter: "any", status: ["contacted"]}
        assert_response :success
      end
    end

    context "Search Person" do
      should "search by first name" do
        xhr :get, :index, {:advanced_search => "1", :search_any => "bc"}
        assert_response :success
        assert_equal 2, assigns(:people).total_count
      end
      should "search by last name" do
        xhr :get, :index, {:advanced_search => "1", :search_any => "rs"}
        assert_response :success
        assert_equal 2, assigns(:people).total_count
      end
      should "search by email" do
        xhr :get, :index, {:advanced_search => "1", :search_any => "contact"}
        assert_response :success
        assert_equal 2, assigns(:people).total_count
      end
      should "search by phone" do
        xhr :get, :index, {:advanced_search => "1", :search_any => "222"}
        assert_response :success
        assert_equal 2, assigns(:people).total_count
      end
    end

    context "Search by Contact Data" do
      setup do
        @person.update_attribute(:gender, nil)
        @contact1.update_attribute(:gender, 1)
        @contact2.update_attribute(:gender, 1)
        @contact3.update_attribute(:gender, 0)
        @contact3.update_attribute(:faculty, true)
        @assignment = FactoryGirl.create(:contact_assignment, organization: @org, person: @contact1, assigned_to: @person).inspect

        @contact1.permission_for_org(@org).update_attribute(:followup_status, 'contacted')
        @contact2.permission_for_org(@org).update_attribute(:followup_status, 'completed')
      end
      # Gender
      should "search by gender - male" do
        xhr :get, :index, {:advanced_search => "1", :gender => "1"}
        assert_response :success
        assert_equal 2, assigns(:people).total_count
      end
      should "search by gender - female" do
        xhr :get, :index, {:advanced_search => "1", :gender => "0"}
        assert_response :success
        assert_equal 1, assigns(:people).total_count
      end
      should "search by gender - no_response" do
        xhr :get, :index, {:advanced_search => "1", :gender => "no_response"}
        assert_response :success
        assert_equal 1, assigns(:people).total_count
      end
      # Faculty
      should "search by faculty - yes" do
        xhr :get, :index, {:advanced_search => "1", :faculty => "1"}
        assert_response :success
        assert_equal 1, assigns(:people).total_count
      end
      should "search by faculty - no" do
        xhr :get, :index, {:advanced_search => "1", :faculty => "0"}
        assert_response :success
        assert_equal 3, assigns(:people).total_count
      end
      # Assigned
      should "search by assignment - yes" do
        xhr :get, :index, {:advanced_search => "1", :assignment => "1"}
        assert_response :success
        assert_equal 1, assigns(:people).total_count
      end
      should "search by assignment - no" do
        xhr :get, :index, {:advanced_search => "1", :assignment => "0"}
        assert_response :success
        assert_equal 3, assigns(:people).total_count
      end
      # Status
      should "search by status - uncontacted & blank" do
        xhr :get, :index, {:advanced_search => "1", :status => "uncontacted"}
        assert_response :success
        assert_equal 1, assigns(:people).total_count
      end
      should "search by status - contacted" do
        xhr :get, :index, {:advanced_search => "1", :status => "contacted"}
        assert_response :success
        assert_equal 1, assigns(:people).total_count
      end
      should "search by status - completed" do
        xhr :get, :index, {:advanced_search => "1", :status => "completed"}
        assert_response :success
        assert_equal 1, assigns(:people).total_count
      end
    end

    context "Search by Label & Group" do
      setup do
        FactoryGirl.create(:organizational_label, organization: @org, person: @contact1, label: Label.involved)
        FactoryGirl.create(:organizational_label, organization: @org, person: @contact2, label: Label.involved)
        FactoryGirl.create(:organizational_label, organization: @org, person: @contact2, label: Label.leader)
        FactoryGirl.create(:organizational_label, organization: @org, person: @contact3, label: Label.leader)

        @group1 = FactoryGirl.create(:group, organization: @org, name: "Test Group 1")
        @group2 = FactoryGirl.create(:group, organization: @org, name: "Test Group 2")
        FactoryGirl.create(:group_membership, group: @group1, person: @contact1)
        FactoryGirl.create(:group_membership, group: @group1, person: @contact2)
        FactoryGirl.create(:group_membership, group: @group2, person: @contact2)
        FactoryGirl.create(:group_membership, group: @group2, person: @contact3)
      end

      context "search by label (match any)" do
        should "return any people with 1 selected label" do
          xhr :get, :index, {:advanced_search => "1", label_filter: "any", label: [Label.involved.id]}
          assert_response :success
          assert_equal 2, assigns(:people).total_count
        end
        should "return any people with 2 selected label" do
          xhr :get, :index, {:advanced_search => "1", label_filter: "any", label: [Label.involved.id, Label.leader.id]}
          assert_response :success
          assert_equal 3, assigns(:people).total_count
        end
      end

      context "search by label (match all)" do
        should "return any people with 1 selected label" do
          xhr :get, :index, {:advanced_search => "1", label_filter: "all", label: [Label.involved.id]}
          assert_response :success
          assert_equal 2, assigns(:people).total_count
        end
        should "return any people with 2 selected label" do
          xhr :get, :index, {:advanced_search => "1", label_filter: "all", label: [Label.involved.id, Label.leader.id]}
          assert_response :success
          assert_equal 1, assigns(:people).total_count
        end
      end

      context "search by group match any" do
        should "return any people with 1 selected group" do
          xhr :get, :index, {:advanced_search => "1", group_filter: "any", group: [@group1.id]}
          assert_response :success
          assert_equal 2, assigns(:people).total_count
        end
        should "return any people with 2 selected group" do
          xhr :get, :index, {:advanced_search => "1", group_filter: "any", group: [@group1.id, @group2.id]}
          assert_response :success
          assert_equal 3, assigns(:people).total_count
        end
      end

      context "search by group match all" do
        should "return any people with 1 selected group" do
          xhr :get, :index, {:advanced_search => "1", group_filter: "all", group: [@group1.id]}
          assert_response :success
          assert_equal 2, assigns(:people).total_count
        end
        should "return any people with 2 selected group" do
          xhr :get, :index, {:advanced_search => "1", group_filter: "all", group: [@group1.id, @group2.id]}
          assert_response :success
          assert_equal 1, assigns(:people).total_count
        end
      end
    end
  end

  should "redirect when there is no current_organization" do
    get :index
    assert_response :redirect
  end

  context "Viewing the new All Contacts page" do
    context "when user is implied admin" do
      setup do
        @user = FactoryGirl.create(:user_with_auxs)
        @person = @user.person
        @org = FactoryGirl.create(:organization)
        sign_in @user
        @request.session[:current_organization_id] = @org.id

        @child_org = FactoryGirl.create(:organization, ancestry: @org.id)
        FactoryGirl.create(:organizational_permission, person: @person, organization: @org, permission: Permission.admin)

        @predefined = FactoryGirl.create(:survey, organization: @org)
        ENV['PREDEFINED_SURVEY'] = @predefined.id.to_s
        @year_in_school_question = FactoryGirl.create(:year_in_school_element)
        @predefined.questions << @year_in_school_question
      end

      should "show the admin permission" do
        get :all_contacts
        assert assigns(:permissions_for_assign).include?(Permission.admin), assigns(:permissions_for_assign).inspect
      end
    end
    context "when user is admin" do
      setup do
        @user = FactoryGirl.create(:user_with_auxs)
        @person = @user.person
        @org = FactoryGirl.create(:organization)
        sign_in @user
        @request.session[:current_organization_id] = @org.id

        @child_org = FactoryGirl.create(:organization, ancestry: @org.id)
        FactoryGirl.create(:organizational_permission, person: @person, organization: @org, permission: Permission.admin)

        @predefined = FactoryGirl.create(:survey, organization: @org)
        ENV['PREDEFINED_SURVEY'] = @predefined.id.to_s
        @year_in_school_question = FactoryGirl.create(:year_in_school_element)
        @predefined.questions << @year_in_school_question

      end
      #
      # context "filter by interaction_types" do
      #   setup do
      #     @interaction_type1 = FactoryGirl.create(:interaction_type, organization_id: 0, i18n: "Interaction 1")
      #     @interaction_type2 = FactoryGirl.create(:interaction_type, organization_id: 0, i18n: "Interaction 2")
      #     @person1 = FactoryGirl.create(:person)
      #     @person2 = FactoryGirl.create(:person)
      #     @person3 = FactoryGirl.create(:person)
      #     @org.add_contact(@person1)
      #     @org.add_contact(@person2)
      #     @org.add_contact(@person3)
      #     FactoryGirl.create(:interaction, receiver: @person1, creator: @person, organization: @org, interaction_type_id: @interaction_type1.id)
      #     FactoryGirl.create(:interaction, receiver: @person2, creator: @person, organization: @org, interaction_type_id: @interaction_type1.id)
      #     FactoryGirl.create(:interaction, receiver: @person3, creator: @person, organization: @org, interaction_type_id: @interaction_type2.id)
      #   end
      #
      #   should "return people with specified interaction" do
      #     get :all_contacts, interaction_type: @interaction_type1.id
      #     assert_response :success
      #     assert assigns(:people).include?(@person1)
      #     assert assigns(:people).include?(@person2)
      #     assert !assigns(:people).include?(@person3)
      #   end
      #
      # end
    end
  end

  context "After logging in a person with orgs" do
    setup do
      @user, org = admin_user_login_with_org
      FactoryGirl.create(:email_address, email: 'leader1@email.com', person: @user.person)
      @user.person.reload
      @keyword = FactoryGirl.create(:sms_keyword)
      @user.person.organizations.first.add_leader(@user.person, @user.person)
      @org = org

      @predefined = FactoryGirl.create(:survey, organization: org)
      ENV['PREDEFINED_SURVEY'] = @predefined.id.to_s
      @year_in_school_question = FactoryGirl.create(:year_in_school_element)
      @predefined.questions << @year_in_school_question
    end

    should "be able to show a person" do
      xhr :get, :show, {:id => @user.person.id}
      assert_response :redirect
    end

    should "be able to edit a person" do
      xhr :get, :edit, {:id => @user.person.id}
      assert_response :redirect
    end

    context "creating a new contact manually" do
      should "create a person with only an email address" do
        xhr :post, :create, {"assigned_to" => "all", "dnc" => "", "person" => {"email_address" => {"email" => "test@uscm.org"},"first_name" => "Test","last_name" => "Test",  "phone_number" => {"number" => ""}}}
        assert_response :success, @response.body
      end

      should "create a person with email and phone number" do
        xhr :post, :create, {
                        "person" => {
                          "current_address_attributes" => {
                            "country" => "US"
                          },
                          "email_address" => {
                            "_destroy" => "false",
                            "email" => "trbooth@uark.edu",
                            "primary" => "0"
                          },
                          "first_name" => "Tyler",
                          "gender" => "male",
                          "last_name" => "Booth",
                          "phone_number" => {
                            "_destroy" => "false",
                            "location" => "mobile",
                            "number" => "479-283-4946",
                            "primary" => "0"
                          }
                        }
                      }
        assert_response :success, @response.body
      end

      should "render the form with errors if email is bad" do
        xhr :post, :create, {
                        "person" => {
                          "email_address" => {
                            "email" => "trbooth@asdf",
                          },
                          "first_name" => "Tyler",
                          "gender" => "male",
                          "last_name" => "Booth",
                          "phone_number" => {
                            "number" => "479-283-4946",
                          }
                        }
                      }
        assert_response :success, @response.body
      end

      should "create a person even though inserted email has trailing spaces" do

        assert_difference "Person.count" do
          xhr :post, :create, {
                          "person" => {
                            "email_address" => {
                              "email" => "trboothshoomy@email.com ",
                            },
                            "first_name" => "Tyler",
                            "gender" => "male",
                            "last_name" => "Booth",
                            "phone_number" => {
                              "number" => "479-283-4946",
                            }
                          }
                        }

          end
        assert_response :success, @response.body
      end

      should "remove the being 'archived' Contact permission of a Person when it is going to be created again (using existing first_name, last_name and email) in 'My Contacts' tab (:assign_to_me => true)" do
        contact = FactoryGirl.create(:person, first_name: "Jon", last_name: "Snow")
        FactoryGirl.create(:email_address, email: "jonsnow@email.com", person: contact)
        FactoryGirl.create(:organizational_permission, permission: Permission.no_permissions, person: contact, organization: @org)
        assert_not_empty contact.organizational_permissions.where(permission_id: Permission.no_permissions.id)
        assert_not_empty @org.contacts.joins(:email_addresses).where(first_name: "Jon", last_name: "Snow", "email_addresses.email" => "jonsnow@email.com")
        #archive contact permission
        contact.organizational_permissions.where(permission_id: Permission.no_permissions.id).first.archive
        assert_empty contact.organizational_permissions.where(permission_id: Permission.no_permissions.id)
        assert_empty @org.contacts.joins(:email_addresses).where(first_name: "Jon", last_name: "Snow", "email_addresses.email" => "jonsnow@email.com")
        xhr :post, :create, {:assign_to_me => "true", :person => {:first_name => "Jon", :last_name => "Snow", :gender =>"male", :email_address => {:email => "jonsnow@email.com", :primary => 1}}}
        #assert_not_empty contact.organizational_permissions.where(permission_id: Permission.no_permissions.id), "Contact permission of contact not unarchived"
        #assert_not_empty @org.contacts.joins(:email_addresses).where(first_name: "Jon", last_name: "Snow", "email_addresses.email" => "jonsnow@email.com")
      end

      should "remove the being 'archived' Contact permission of a Person when it is going to be created again (using existing first_name, last_name and email) in 'All Contacts' tab" do
        contact = FactoryGirl.create(:person, first_name: "Jon", last_name: "Snow")
        FactoryGirl.create(:email_address, email: "jonsnow@email.com", person: contact)
        FactoryGirl.create(:organizational_permission, permission: Permission.no_permissions, person: contact, organization: @org)
        assert_not_empty contact.organizational_permissions.where(permission_id: Permission.no_permissions.id)
        assert_not_empty @org.contacts.joins(:email_addresses).where(first_name: "Jon", last_name: "Snow", "email_addresses.email" => "jonsnow@email.com")
        #archive contact permission
        contact.organizational_permissions.where(permission_id: Permission.no_permissions.id).first.archive
        assert_empty contact.organizational_permissions.where(permission_id: Permission.no_permissions.id)
        assert_empty @org.contacts.joins(:email_addresses).where(first_name: "Jon", last_name: "Snow", "email_addresses.email" => "jonsnow@email.com")
        xhr :post, :create, {:person => {:first_name => "Jon", :last_name => "Snow", :gender =>"male", :email_address => {:email => "jonsnow@email.com", :primary => 1}}}
        #assert_not_empty contact.organizational_permissions.where(permission_id: Permission.no_permissions.id), "Contact permission of contact not unarchived"
        #assert_not_empty @org.contacts.joins(:email_addresses).where(first_name: "Jon", last_name: "Snow", "email_addresses.email" => "jonsnow@email.com")
      end
    end

    context "on index page" do
      setup do
        @organization = FactoryGirl.create(:organization)
        @keyword = FactoryGirl.create(:approved_keyword, organization: @organization)
        get :index, org_id: @organization.id
      end
      should respond_with(:success)
    end

    should "update a contact's info" do
      @contact = FactoryGirl.create(:person)
      @user.person.organizations.first.add_contact(@contact)
      put :update, id: @contact.id, person: {first_name: 'Frank'}
      assert_redirected_to survey_response_path(@contact)
      assert_equal(assigns(:person).id, @contact.id)
    end

    should "update a contact's survey answers" do
      @contact = FactoryGirl.create(:person)
      @user.person.organizations.first.add_contact(@contact)

      @survey = FactoryGirl.create(:survey, organization: @org)
      @question = FactoryGirl.create(:element, object_name: nil, attribute_name: nil)
      @survey.questions << @question

      @answer_sheet = FactoryGirl.create(:answer_sheet, survey: @survey, person: @contact)
      @answer = FactoryGirl.create(:answer, answer_sheet: @answer_sheet, question: @question, value: "ExistingValue")

      put :update, id: @contact.id, answers: {"#{@survey.id}"=>{"#{@question.id}"=>"NewValue"}}
      assert_equal "NewValue", @contact.answer_sheets.first.answers.first.value, "survey answer should be updated"
      assert_redirected_to survey_response_path(@contact)
    end

    should "update a contact's predefined survey answers" do
      @contact = FactoryGirl.create(:person, room: 'OldSchoolYear')
      @user.person.organizations.first.add_contact(@contact)

      @survey = FactoryGirl.create(:survey, organization: @org)
      @question = FactoryGirl.create(:element, object_name: 'person', attribute_name: 'year_in_school')
      @survey.questions << @question

      put :update, id: @contact.id, answers: {"#{@survey.id}"=>{"#{@question.id}"=>"NewSchoolYear"}}
      @contact.reload
      assert_equal "NewSchoolYear", @contact.year_in_school, "person should be updated"
      assert_redirected_to survey_response_path(@contact)
    end

    should "not update a contact when birth_date is invalid format" do
      @contact = FactoryGirl.create(:person, birth_date: nil)
      @user.person.organizations.first.add_contact(@contact)

      @birth_date_question = FactoryGirl.create(:element, object_name: 'person', attribute_name: 'birth_date')
      @predefined.questions << @birth_date_question

      put :update, id: @contact.id, answers: {"#{@predefined.id}"=>{"#{@birth_date_question.id}"=>"InvalidFormat"}}
      @contact.reload
      assert_nil @contact.birth_date, "birth_date should still be nil"
      assert_redirected_to edit_survey_response_path(@contact)
    end

    should "update a contact when birth_date is valid" do
      @contact = FactoryGirl.create(:person, birth_date: nil)
      @user.person.organizations.first.add_contact(@contact)

      @birth_date_question = FactoryGirl.create(:element, object_name: 'person', attribute_name: 'birth_date')
      @predefined.questions << @birth_date_question

      put :update, id: @contact.id, answers: {"#{@predefined.id}"=>{"#{@birth_date_question.id}"=>"02/13/1989"}}
      @contact.reload
      assert_equal "1989-02-13".to_date, @contact.birth_date, "birth_date should be updated"
      assert_redirected_to survey_response_path(@contact)
    end

    should "not update an invalid contact's info'" do
      @contact = FactoryGirl.build(:person_without_name)
      @contact.save(validate: false)
      @user.person.organizations.first.add_contact(@contact)
      put :update, id: @contact.id, person: {last_name: 'Jake'}
      assert_redirected_to survey_response_path(@contact)
    end

    should "remove a contact from an organization" do
       @contact = FactoryGirl.create(:person)
       @user.person.organizations.first.add_contact(@contact)

       xhr :delete, :destroy, :id => @contact.id
       assert_response :success
    end

    should "bulk remove contacts from an organization" do
       @contact = FactoryGirl.create(:person)
       @contact2 = FactoryGirl.create(:person)
       @user.person.organizations.first.add_contact(@contact)

       xhr :post, :bulk_destroy, :ids => [@contact.id, @contact2.id]
       assert_response :success
    end

    context "every params" do
      setup do
        @contact1 = FactoryGirl.create(:person)
        @contact2 = FactoryGirl.create(:person)
        @contact3 = FactoryGirl.create(:person)
        @contact4 = FactoryGirl.create(:person)
        @contact5 = FactoryGirl.create(:person)
        FactoryGirl.create(:email_address, email: 'user@email.com', person: @user.person)
        @user.person.organizations.first.add_leader(@user.person, @user.person)
        @user.person.organizations.first.add_contact(@contact1)
        @user.person.organizations.first.add_contact(@contact2)
        @user.person.organizations.first.add_contact(@contact3)
        @user.person.organizations.first.add_contact(@contact4)
        @user.person.organizations.first.add_contact(@contact5)
      end

      should "have header when viewing unassigned contacts" do
        xhr :get, :index, {:assigned_to => "unassigned"}
        assert_equal assigns(:header), "Unassigned"
      end
      should "have header when viewing completed contacts" do
        xhr :get, :index, {:completed => "true"}
        assert_equal assigns(:header), "Completed"
      end
      should "not have header for when not assigned to any" do
        xhr :get, :index, {:assigned_to => nil}
        assert_nil assigns(:header)
      end
      should "have header when viewing no_activity" do
        xhr :get, :index, {:assigned_to => "no_activity"}
        assert_equal assigns(:header), "No Activity"
      end
      should "have header when viewing spiritual_conversation" do
        xhr :get, :index, {:assigned_to => "spiritual_conversation"}
        assert_equal assigns(:header), "Spiritual Conversation"
      end
      should "have header when viewing prayed_to_receive" do
        xhr :get, :index, {:assigned_to => "prayed_to_receive"}
        assert_equal assigns(:header), "Prayed To Receive Christ"
      end
      should "have header when viewing gospel_presentation" do
        xhr :get, :index, {:assigned_to => "gospel_presentation"}
        assert_equal assigns(:header), "Gospel Presentation"
      end
      should "have header when viewing friends" do
        xhr :get, :index, {:assigned_to => "friends"}
        assert_equal assigns(:header), "Contacts who are also my friends on Facebook"
      end
      should "have header when viewing do_not_contact" do
        xhr :get, :index, {:dnc => "true"}
        assert_equal assigns(:header), "Do Not Contact"
      end
      should "have header when searching" do
        xhr :get, :index, {:do_search => "1"}
        assert_equal assigns(:header), "Matching the criteria you searched for"
      end
      should "have header for assigned to specific person" do
        xhr :get, :index, {:assigned_to => @user.person.id}
        assert_equal "Assigned to #{@user.person.name}", assigns(:header)
      end
    end

    should "get unassigned contacts ONLY" do
      @contact1 = FactoryGirl.create(:person)
      @contact2 = FactoryGirl.create(:person)
      @contact3 = FactoryGirl.create(:person)
      @contact4 = FactoryGirl.create(:person)
      @contact5 = FactoryGirl.create(:person)

      @org.add_leader(@user.person, @user.person)
      @org.add_contact(@contact1)
      @org.add_contact(@contact2)
      @org.add_contact(@contact3)
      @org.add_contact(@contact4)

      xhr :get, :index, {:assigned_to => "unassigned"}
      assert_equal [@user.person.id, @contact1.id, @contact2.id, @contact3.id, @contact4.id], assigns(:people).collect(&:id).sort
    end

  end

  context "When retrieving permissions depending on current user permission" do
    context "When user is admin" do
      setup do
        @user = FactoryGirl.create(:user_with_auxs)  #user with a person object
        org = FactoryGirl.create(:organization)
        FactoryGirl.create(:organizational_permission, person: @user.person, permission: Permission.admin, organization: org)
        sign_in @user
        @request.session[:current_organization_id] = org.id

        @predefined = FactoryGirl.create(:survey, organization: org)
        ENV['PREDEFINED_SURVEY'] = @predefined.id.to_s
        @predefined.questions << FactoryGirl.create(:year_in_school_element)
      end

      should "get all permissions" do
        get :index
        assert_response(:success)
        assert(assigns(:permissions_for_assign).include? Permission.admin)

        get :mine
        assert_response(:success)
        assert(assigns(:permissions_for_assign).include? Permission.admin)
      end
    end

    context "When user is leader" do
      setup do
        @user = FactoryGirl.create(:user_with_auxs)
        @user2 = FactoryGirl.create(:user_with_auxs)
        org = FactoryGirl.create(:organization)

        FactoryGirl.create(:email_address, email: 'user@email.com', person: @user.person)
        FactoryGirl.create(:email_address, email: 'user2@email.com', person: @user2.person)
        @user.person.reload
        @user2.person.reload
        FactoryGirl.create(:organizational_permission, person: @user.person, permission: Permission.user, organization: org, :added_by_id => @user2.person.id)
        sign_in @user
        @request.session[:current_organization_id] = org.id

        @predefined = FactoryGirl.create(:survey, organization: org)
        ENV['PREDEFINED_SURVEY'] = @predefined.id.to_s
        @predefined.questions << FactoryGirl.create(:year_in_school_element)
      end

      should "not include admin permission if user is not admin" do
        get :index
        assert_response(:success)
        assert(!(assigns(:permissions_for_assign).include? Permission.admin))

        get :mine
        assert_response(:success)
        assert(!(assigns(:permissions_for_assign).include? Permission.admin))
      end
    end

  end

  context "After logging in a person without orgs" do
    setup do
      #@user = FactoryGirl.create(:user)
      @user = FactoryGirl.create(:user_no_org)  #user with a person object
      sign_in @user
      @organization = FactoryGirl.create(:organization)
      @keyword = FactoryGirl.create(:approved_keyword, organization: @organization, user: @user)
    end

    context "on index page" do
      setup do
        get :index
      end
      should "show dashboard info page" do
        assert_response :redirect
      end
    end
  end

  context "After logging in as a contact" do
    setup do
      @user = FactoryGirl.create(:user_no_org)  #user with a person object
      @organization = FactoryGirl.create(:organization)
      @organizational_permission = FactoryGirl.create(:organizational_permission, person: @user.person, organization: @organization, :permission => Permission.no_permissions)
      sign_in @user
    end

    context "on index page" do
      setup do
        get :index
      end
      should "show dashboard" do
        assert_response :redirect
      end
    end
  end

  test "send reminder" do
    #Resque.reset!
    user1 = FactoryGirl.create(:user_with_auxs)
    user2 = FactoryGirl.create(:user_with_auxs)

    user, org = admin_user_login_with_org

    #org.add_leader(user1.person, user.person)
    #org.add_leader(user2.person, user.person)
    FactoryGirl.create(:organizational_permission, person: user1.person, organization: org, permission: Permission.user)
    FactoryGirl.create(:organizational_permission, person: user2.person, organization: org, permission: Permission.user)

    xhr :post, :send_reminder, { :to => "#{user1.person.id}, #{user2.person.id}" }

    assert_equal "", response.body
    assert Sidekiq::Extensions::DelayedMailer.jobs.size > 0
  end

  context "Search by name or email" do
    setup do
      @user1 = FactoryGirl.create(:user_with_auxs)
      @user2 = FactoryGirl.create(:user_with_auxs)

      @user, @org = admin_user_login_with_org
      FactoryGirl.create(:organizational_permission, organization: @org, person: @user.person, permission: Permission.user)
      @person1 = FactoryGirl.create(:person, first_name: "Neil Marion", last_name: "dela Cruz", email: "ndc@email.com")
      FactoryGirl.create(:organizational_permission, organization: @org, person: @person1, permission: Permission.no_permissions)
      @person2 = FactoryGirl.create(:person, first_name: "Johnny", last_name: "English", email: "english@email.com")
      FactoryGirl.create(:organizational_permission, organization: @org, person: @person2, permission: Permission.no_permissions)
      @person3 = FactoryGirl.create(:person, first_name: "Johnny", last_name: "Bravo", email: "bravo@email.com")
      FactoryGirl.create(:organizational_permission, organization: @org, person: @person3, permission: Permission.no_permissions)
      @person4 = FactoryGirl.create(:person, first_name: "Neil", last_name: "O'neil", email: "neiloneil@email.com")
      FactoryGirl.create(:organizational_permission, organization: @org, person: @person4, permission: Permission.no_permissions)
    end


    should "find people by name or email given wildcard strings" do


      xhr :get, :search_by_name_and_email, { :term => "Neil" } # should be able to find a leader as well
      assert_response :success, response
      res = ActiveSupport::JSON.decode(response.body)
      assert_equal res[0]['id'], @person1.id
      assert_equal res[0]['label'], @person1.name
      assert_equal res[0]['email'], @person1.email

      xhr :get, :search_by_name_and_email, { :term => "ndc" } #should be able to find by an email address wildcard
      assert_response :success, response
      res = ActiveSupport::JSON.decode(response.body)
      assert_equal res[0]['id'], @person1.id
      assert_equal res[0]['label'], @person1.name
      assert_equal res[0]['email'], @person1.email

      xhr :get, :search_by_name_and_email, { :term => "hnny" } #should be able to find contacts
      assert_response :success, response
      res = ActiveSupport::JSON.decode(response.body)
      assert_equal res.count, 2

      xhr :get, :search_by_name_and_email, { :term => "O'neil" } # should be able to find a person even a wildcard has non-alpha characters
      assert_response :success, response
      res = ActiveSupport::JSON.decode(response.body)
      assert_equal res[0]['id'], @person4.id
      assert_equal res[0]['label'], @person4.name
      assert_equal res[0]['email'], @person4.email
    end

    should "strip trailing whitespaces of search terms" do
      xhr :get, :search_by_name_and_email, { :term => "Neil     " }
      assert_response :success, response
      res = ActiveSupport::JSON.decode(response.body)
      assert_equal res[0]['id'], @person1.id
      assert_equal res[0]['label'], @person1.name
      assert_equal res[0]['email'], @person1.email
    end

  end

  context "Searching for contacts using 'Saved Searches'" do
    setup do

      @user, org = admin_user_login_with_org
      sign_in @user

      @contact1 = FactoryGirl.create(:person, first_name: "Neil", last_name: "delaCruz")
      @org.add_contact(@contact1)

      @predefined = FactoryGirl.create(:survey, organization: @org)
      ENV['PREDEFINED_SURVEY'] = @predefined.id.to_s
      @predefined.questions << FactoryGirl.create(:year_in_school_element)
    end

    should "search for contacts" do

      xhr :get, :index, {:do_search => "1", :first_name => "Neil", :last_name => "delaCruz"}
      assert_response :success
    end
    #more tests to come
  end

  context "Searching for people using search_autocomplete_field" do
    setup do
      @user = FactoryGirl.create(:user_with_auxs)
      sign_in @user

      @archived_contact1 = FactoryGirl.create(:person, first_name: "Edmure", last_name: "Tully")
      FactoryGirl.create(:organizational_permission, organization: @user.person.organizations.first, person: @archived_contact1, permission: Permission.no_permissions)
      @archived_contact1.organizational_permissions.where(permission_id: Permission::NO_PERMISSIONS_ID).first.archive #archive his one and only permission

      @unarchived_contact1 = FactoryGirl.create(:person, first_name: "Brynden", last_name: "Tully")
      FactoryGirl.create(:organizational_permission, organization: @user.person.organizations.first, person: @unarchived_contact1, permission: Permission.no_permissions)
      FactoryGirl.create(:email_address, email: "bryndentully@email.com", person: @unarchived_contact1, primary: true)
    end

    should "not be able to search for archived contacts if 'Include Archvied' checkbox is not checked" do
      xhr :get, :search_by_name_and_email, {:term => "Edmure Tully"}
      assert !assigns(:people).include?(@archived_contact1)
    end

    should "be able to search for archived contacts if 'Include Archvied' checkbox is checked" do
      xhr :get, :search_by_name_and_email, {:include_archived => "true", :term => "Edmure Tully"}
      assert assigns(:people).include?(@archived_contact1)
    end

    should "be able to search by email address" do
      xhr :get, :search_by_name_and_email, {:term => "Brynden Tully"}
      assert assigns(:people).include?(@unarchived_contact1)
    end

    should "be able to search by wildcard" do
      xhr :get, :search_by_name_and_email, {:include_archived => "true", :term => "tully"}
      assert assigns(:people).include?(@archived_contact1), "archived contact not found"
      assert assigns(:people).include?(@unarchived_contact1), "unarchived contact not found"
    end

    should "not be able to search for anything" do
      xhr :get, :search_by_name_and_email, {:include_archived => "true", :term => "none"}
      assert_empty assigns(:people)
    end
  end

  context "exporting contacts" do
    setup do
      @user, org = admin_user_login_with_org

      @predefined = FactoryGirl.create(:survey, organization: org)
      ENV['PREDEFINED_SURVEY'] = @predefined.id.to_s
      @predefined.questions << FactoryGirl.create(:year_in_school_element)

      @contact1 = FactoryGirl.create(:person)
      FactoryGirl.create(:organizational_permission, permission: Permission.no_permissions, organization: org, person: @contact1)
      @contact2 = FactoryGirl.create(:person)
      FactoryGirl.create(:organizational_permission, permission: Permission.no_permissions, organization: org, person: @contact2)
      @admin1 = FactoryGirl.create(:person)
      FactoryGirl.create(:organizational_permission, permission: Permission.admin, organization: org, person: @admin1)

      @survey = FactoryGirl.create(:survey, organization: org) #create survey
      @keyword = FactoryGirl.create(:approved_keyword, organization: org, survey: @survey) #create keyword
      @notify_q = FactoryGirl.create(:choice_field, notify_via: "Both", trigger_words: "Jesus") #create question
      @email_q = FactoryGirl.create(:email_element)
      @survey.questions << @notify_q
      @survey.questions << @email_q
      @questions = @survey.questions
      assert_equal(@questions.count, 2)


      @answer_sheet = FactoryGirl.create(:answer_sheet, survey: @survey, person: @contact1)
      @answer = FactoryGirl.create(:answer, answer_sheet: @answer_sheet, question: @notify_q, value: "Jesus", short_value: "Jesus")
    end

    should "export all people" do
      xhr :get, :index, {:assigned_to => "all", :format => "csv"}
      assert_equal 4, assigns(:all_people).length
      assert_response :success
    end

    should "export selected people only" do
      xhr :get, :index, {:assigned_to => "all", :format => "csv", only_ids: @contact1.id.to_s}
      assert assigns(:all_people).include?(@contact1)
      assert_equal(assigns(:all_people).length, 1)
      assert_response :success
    end

  end

  context "retrieving contacts" do
    setup do
      @user, org = admin_user_login_with_org
      @organization = org
      @contact1 = FactoryGirl.create(:person)
      @contact2 = FactoryGirl.create(:person)
      FactoryGirl.create(:organizational_permission, permission: Permission.no_permissions, organization: org, person: @contact1) #make them contacts in the org
      FactoryGirl.create(:organizational_permission, permission: Permission.no_permissions, organization: org, person: @contact2) #make them contacts in the org

      @survey = FactoryGirl.create(:survey, organization: org) #create survey
      @keyword = FactoryGirl.create(:approved_keyword, organization: org, survey: @survey) #create keyword
      @notify_q = FactoryGirl.create(:choice_field, notify_via: "Both", trigger_words: "Jesus") #create question
      @email_q = FactoryGirl.create(:email_element)
      @phone_q = FactoryGirl.create(:phone_element)
      @gender_q = FactoryGirl.create(:gender_element)
      @some_q = FactoryGirl.create(:some_question)
      #puts @some_q.object_name.present?
      #puts @some_q.inspect
      @survey.questions << @notify_q
      @survey.questions << @email_q
      @survey.questions << @phone_q
      @survey.questions << @gender_q
      @survey.questions << @some_q
      @questions = @survey.questions
      assert_equal(@questions.count, 5)

      @answer_sheet = FactoryGirl.create(:answer_sheet, survey: @survey, person: @contact1)
      @answer = FactoryGirl.create(:answer, answer_sheet: @answer_sheet, question: @notify_q, value: "Jesus", short_value: "Jesus")

      @phone_number = FactoryGirl.create(:phone_number, person: @contact1, number: "09167788889", primary: true)

      @predefined = FactoryGirl.create(:survey, organization: org)
      ENV['PREDEFINED_SURVEY'] = @predefined.id.to_s
      @predefined.questions << FactoryGirl.create(:year_in_school_element)
    end

    should "retrieve 'mine' contacts" do
      xhr :get, :mine, {:status => "completed"}
      assert_response :success
    end

    should "retrieve contacts with survey answers" do
      xhr :get, :index, {:do_search => 1, :answers => {"#{@notify_q.id}" => {"1" => 1, "2" => 2}, "#{@email_q.id}" => "email@email.com", "#{@some_q.id}" => "hello", "#{@phone_q.id}" => "12311311231231", "#{@gender_q.id}" => "male"}}
      assert_response :success
    end

    should "retrive contacts according to latest answer sheets answered" do
      xhr :get, :index, {:do_search => 1, :search=>{:meta_sort=>"MAX(answer_sheets.updated_at) asc"}}
      assert_response :success
    end

    should "retrive contacts according to surveys answered" do
      xhr :get, :index, {:do_search => 1, :survey => @survey.id}
      assert_response :success
    end

    should "retrive contacts searching by first_name" do
      xhr :get, :index, {:do_search => 1, :first_name => "Neil"}
      assert_response :success
    end

    should "retrive contacts searching by last_name" do
      xhr :get, :index, {:do_search => 1, :last_name => "dela Cruz"}
      assert_response :success
    end

    should "retrive contacts searching by email" do
      xhr :get, :index, {:do_search => 1, :email => "email@email.com"}
      assert_response :success
    end

    should "retrive contacts searching by phone_number" do
      xhr :get, :index, {:do_search => 1, :phone_number => "09167788889"}
      assert_equal [@contact1], assigns(:people)
      assert_response :success
    end

    should "retrive contacts searching by phone_number wildcard" do
      xhr :get, :index, {:do_search => 1, :phone_number => "88889"}
      assert_equal [@contact1], assigns(:people)
      assert_response :success
    end

    should "retrive contacts searching by gender" do
      xhr :get, :index, {:do_search => 1, :gender => "Male"}
      assert_response :success
    end

    should "retrive contacts searching by status" do
      xhr :get, :index, {:do_search => 1, :status => "uncontacted"}
      assert_response :success
    end

    should "retrive contacts searching by date updated" do
      xhr :get, :index, {:do_search => 1, :person_updated_from => "05-08-2012", :person_updated_to => "05-08-2012"}
      assert_response :success
    end

    should "retrive contacts searching by basic search_type" do
      xhr :get, :index, {:do_search => 1, :search_type => "basic"}
      assert_response :success
    end

    should "retrive contacts searching by group" do
      group = FactoryGirl.create(:group, organization: @organization, name: "sample")
      FactoryGirl.create(:group_membership, group: group, person: @contact1)
      FactoryGirl.create(:group_membership, group: group, person: @contact2)

      xhr :get, :index, {:do_search => 1, :group_name => "samp"}
      assert_equal 2, assigns(:people).size
      assert_response :success
    end
  end

  context "Creating contacts" do
    setup do
      @user, org = admin_user_login_with_org
      @org = @user.person.organizations.first
      @predefined_survey = FactoryGirl.create(:survey, organization: org)
      ENV['PREDEFINED_SURVEY'] = @predefined_survey.id.to_s
      @year_in_school_question = FactoryGirl.create(:year_in_school_element)
      @predefined_survey.questions << @year_in_school_question

      @simple_survey = FactoryGirl.create(:survey, organization: org)
      @birth_date_question = FactoryGirl.create(:element, object_name: 'person', attribute_name: 'birth_date')
      @simple_survey.questions << @birth_date_question
    end

    should "create an org with answered predefined survey" do
      assert_difference "Person.count", 1 do
        xhr :post, :create, {:person => {:first_name => "James", :last_name => "Ingram", :gender => "male"}, :answers => {"#{@year_in_school_question.id}"=>"4th"}  }
      end
      assert_equal "4th", Person.where(first_name: "James", last_name: "Ingram").first.year_in_school
    end

    should "create record with if birth_date is valid and in non-predefined survey" do
      assert_difference "Person.count", 1 do
        xhr :post, :create, :person => {:first_name => "Any"}, :answers => {"#{@simple_survey.id}" => {"#{@birth_date_question.id}"=>"02/13/1989"}}
      end
      assert_equal "1989-02-13".to_date, Person.last.birth_date
    end

    should "create record with if birth_date is valid and in predefined survey" do
      assert_difference "Person.count", 1 do
        xhr :post, :create, :person => {:first_name => "Any"}, :answers => {"#{@birth_date_question.id}"=>"02/13/1989"}
      end
      assert_equal "1989-02-13".to_date, Person.last.birth_date
    end

    should "not create record if the answer in date question of non-predefined survey is invalid" do
      assert_no_difference "Person.count" do
        xhr :post, :create, :person => {:first_name => "Any"}, :answers => {"#{@simple_survey.id}" => {"#{@birth_date_question.id}"=>"InvalidFormat"}}
      end
      assert_equal "Birth date invalid - should be MM/DD/YYYY", assigns(:person).errors.full_messages.first
    end

    should "not create record if the answer in date question of predefined survey is invalid" do
      assert_no_difference "Person.count" do
        xhr :post, :create, :person => {:first_name => "Any"}, :answers => {"#{@birth_date_question.id}"=>"InvalidFormat"}
      end
      assert_equal "Birth date invalid - should be MM/DD/YYYY", assigns(:person).errors.full_messages.first
    end

    should "create record if only name present" do
      assert_difference "Person.count" do
        xhr :post, :create, :person => {:first_name => "Any"}, :answers => {"#{@simple_survey.id}" => {"#{@birth_date_question.id}"=>""}}
      end
      assert_equal "Any", Person.last.first_name
    end

    should "retain all the labels if there's a merge (creating contact with the same first_name, last_name and email with an existing person in the db)" do
      @person = FactoryGirl.create(:person, email:'abcd@email.com')
      @org.add_contact(@person)
      @org_child = FactoryGirl.create(:organization, :name => "neilmarion", :parent => @user.person.organizations.first, :show_sub_orgs => 1)
      @request.session[:current_organization_id] = @org_child.id

      assert_no_difference "Person.count" do
        xhr :post, :create, {:person => {:first_name => @person.first_name, :last_name => @person.last_name, :email_address => {:email => @person.email, :primary => 1}}, :labels => [Label.leader.id.to_s, Label.involved.id.to_s]}
      end
    end
  end

  context "Sorting contact status" do
    setup do
      @user, org = admin_user_login_with_org

      @person1 = FactoryGirl.create(:person)
      @permission1 = FactoryGirl.create(:organizational_permission, organization: org, permission: Permission.no_permissions, person: @person1)
      @permission1.update_attributes({followup_status: "uncontacted"})
      @person2 = FactoryGirl.create(:person)
      @permission2 = FactoryGirl.create(:organizational_permission, organization: org, permission: Permission.no_permissions, person: @person2)
      @permission2.update_attributes({followup_status: "attempted_contact"})
      @person3 = FactoryGirl.create(:person)
      @permission3 = FactoryGirl.create(:organizational_permission, organization: org, permission: Permission.no_permissions, person: @person3)
      @permission3.update_attributes({followup_status: "contacted"})

      @predefined = FactoryGirl.create(:survey, organization: org)
      ENV['PREDEFINED_SURVEY'] = @predefined.id.to_s
      @predefined.questions << FactoryGirl.create(:year_in_school_element)
    end

    should "sort by status asc" do
      xhr :get, :all_contacts, {:assigned_to => "all", :search =>{:meta_sort => "followup_status asc"}}
      assert_equal [@user.person.id, @person2.id, @person3.id, @person1.id], assigns(:people).collect(&:id)
    end

    should "sort by status desc" do
      xhr :get, :all_contacts, {:assigned_to => "all", :search =>{:meta_sort => "followup_status desc"}}
      assert_equal [@person1.id, @person3.id, @person2.id, @user.person.id], assigns(:people).collect(&:id)
    end
  end

  context "People list" do
    setup do
      @user, org = admin_user_login_with_org
      @contact1 = FactoryGirl.create(:person)
      @contact2 = FactoryGirl.create(:person)
      @contact3 = FactoryGirl.create(:person)
      @contact4 = FactoryGirl.create(:person)
      @contact5 = FactoryGirl.create(:person)

      org.add_contact(@contact1)
      org.add_contact(@contact2)
      org.add_contact(@contact3)
      org.add_contact(@contact4)
      org.add_contact(@contact5)

      @predefined = FactoryGirl.create(:survey, organization: org)
      ENV['PREDEFINED_SURVEY'] = @predefined.id.to_s
      @predefined.questions << FactoryGirl.create(:year_in_school_element)
    end

    should "not display contacts multiple times" do
      xhr :get, :index, {:assigned_to => "all"}
      assert_equal 1, assigns(:people).where(id: @contact1.id).length
      assert_equal 1, assigns(:people).where(id: @contact2.id).length
      assert_equal 1, assigns(:people).where(id: @contact3.id).length
      assert_equal 1, assigns(:people).where(id: @contact4.id).length
      assert_equal 1, assigns(:people).where(id: @contact5.id).length
    end

    should "not display contacts multiple times when by searching phone_numbers" do
      @phone_number1 = FactoryGirl.create(:phone_number, person: @contact1, number: "09167788881", location: "home", primary: true) # included
      @phone_number2 = FactoryGirl.create(:phone_number, person: @contact2, number: "09177788882", location: "home", primary: false)
      @phone_number2 = FactoryGirl.create(:phone_number, person: @contact2, number: "09177788883", location: "office", primary: true)
      @phone_number3 = FactoryGirl.create(:phone_number, person: @contact3, number: "09177788884", location: "home", primary: false)
      @phone_number3 = FactoryGirl.create(:phone_number, person: @contact3, number: "09167788885", location: "office", primary: true) # included
      @phone_number4 = FactoryGirl.create(:phone_number, person: @contact4, number: "09167788886", location: "home", primary: true) # included
      @phone_number4 = FactoryGirl.create(:phone_number, person: @contact4, number: "09167788887", location: "office", primary: false)
      @phone_number4 = FactoryGirl.create(:phone_number, person: @contact5, number: "09167788888", location: "home", primary: false) # included

      xhr :get, :index, {:do_search => "1", :phone_number => '0916'}
      assert_equal 1, assigns(:people).where(id: @contact1.id).length
      assert_equal 1, assigns(:people).where(id: @contact3.id).length
      assert_equal 1, assigns(:people).where(id: @contact4.id).length
      assert_equal 1, assigns(:people).where(id: @contact5.id).length
      assert !assigns(:people).include?(@contact2)
    end
  end

  context "Sorting people" do
    setup do
      @user, @org = admin_user_login_with_org
      @person1 = FactoryGirl.create(:person, first_name: 'One')
      @person2 = FactoryGirl.create(:person, first_name: 'Two')
      @person3 = FactoryGirl.create(:person, first_name: 'Three')
      @person4 = FactoryGirl.create(:person, first_name: 'Four')
      FactoryGirl.create(:organizational_permission, organization: @org, permission: Permission.no_permissions, person: @person1)
      FactoryGirl.create(:organizational_permission, organization: @org, permission: Permission.no_permissions, person: @person2)
      FactoryGirl.create(:organizational_permission, organization: @org, permission: Permission.no_permissions, person: @person3)
      FactoryGirl.create(:organizational_permission, organization: @org, permission: Permission.no_permissions, person: @person4)

      @predefined = FactoryGirl.create(:survey, organization: @org)
      ENV['PREDEFINED_SURVEY'] = @predefined.id.to_s
      @predefined.questions << FactoryGirl.create(:year_in_school_element)
    end

    should "return admins when Admin link is clicked" do
      FactoryGirl.create(:organizational_permission, organization: @org, person: @person1, permission: Permission.admin)
      xhr :get, :index, { :permission => [Permission::ADMIN_ID] }
      assert_equal 2, assigns(:people).total_count, "only 2 record should be returned"
      assert assigns(:people).include?(@person1)
      assert assigns(:people).include?(@user.person)
    end

    should "return leaders when Leader link is clicked" do
      FactoryGirl.create(:organizational_permission, organization: @org, person: @person1, permission: Permission.user)
      xhr :get, :index, { :permission => [Permission::USER_ID] }
      assert_equal 1, assigns(:people).total_count, "only 1 record should be returned"
      assert assigns(:people).include?(@person1)
    end

    should "return contacts when Contact link is clicked" do
      xhr :get, :index, { :permission => [Permission::NO_PERMISSIONS_ID] }
      assert_equal 4, assigns(:people).total_count, "4 records should be returned"
      assert assigns(:people).include?(@person1)
      assert assigns(:people).include?(@person2)
      assert assigns(:people).include?(@person3)
      assert assigns(:people).include?(@person4)
    end

    context "by gender" do
      setup do
        @person1.update_attribute('gender','male')
        @person2.update_attribute('gender','female')
        @person3.update_attribute('gender','female')
      end

      should "sort desc" do
        xhr :get, :index, {:search=>{:meta_sort=>"gender desc"}}
        assert assigns(:people).first.gender == "Male", "first result should be male"
        assert assigns(:people).last.gender == "Female", "last result should be female"
      end

      should "sort asc" do
        xhr :get, :index, {:search=>{:meta_sort=>"gender asc"}}
        assert assigns(:people).first.gender == "Female", "first result should be female"
        assert assigns(:people).last.gender == "Male", "last result should be male"
      end
    end

    context "by phone_numbers" do
      setup do
        @phone_number1 = FactoryGirl.create(:phone_number, person: @person1, location: "home", number: "09167788881", primary: true)
        @phone_number2 = FactoryGirl.create(:phone_number, person: @person2, location: "home", number: "09167788882", primary: true)
        @phone_number3 = FactoryGirl.create(:phone_number, person: @person3, location: "home", number: "09167788883", primary: true)
        @phone_number4 = FactoryGirl.create(:phone_number, person: @person3, location: "office", number: "09167788884", primary: false)
        @phone_number5 = FactoryGirl.create(:phone_number, person: @person3, location: "mobile", number: "09167788885", primary: false)
      end

      should "sort by phone_number should include person without primary_phone_numbers" do
        xhr :get, :all_contacts, {:assigned_to => "all", :search =>{:meta_sort => "phone_numbers.number asc"}}
        assert_equal 7, assigns(:people).size
      end

      # should "sort by phone_number asc" do
      #   xhr :get, :all_contacts, {:assigned_to => "all", :search =>{:meta_sort => "phone_numbers.number asc"}}
      #   assert_equal @person3, assigns(:people).last
      # end
      #
      # should "sort by phone_number desc" do
      #   xhr :get, :all_contacts, {:assigned_to => "all", :search =>{:meta_sort => "phone_numbers.number desc"}}
      #   assert_equal @person3, assigns(:people).first
      # end
    end

    context "by labels" do
      setup do
        FactoryGirl.create(:organizational_label, organization: @org, person: @person1, label: Label.involved)
        FactoryGirl.create(:organizational_label, organization: @org, person: @person2, label: Label.leader)
        FactoryGirl.create(:organizational_label, organization: @org, person: @person3, label: Label.engaged_disciple)
        FactoryGirl.create(:organizational_label, organization: @org, person: @user.person, label: Label.engaged_disciple)
      end

      should "return people sorted by their labels (default labels) asc" do
        xhr :get, :all_contacts, {:search=>{:meta_sort=>"labels.asc"}}
        results = assigns(:people).collect(&:id)
        assert_equal @person1.id, results.first
      end

      should "return people sorted by their labels (default labels) desc" do
        xhr :get, :all_contacts, {:search=>{:meta_sort=>"labels.desc"}}
        results = assigns(:people).collect(&:id)
        assert_equal @person4.id, results.last
      end
    end
  end

  context "Searching for contacts" do
    setup do
      @user, @org = admin_user_login_with_org

      @survey = FactoryGirl.create(:survey, organization: @org)
      @question = FactoryGirl.create(:choice_field_question, content: "SUSD\nUSD") #create question
      @survey.questions << @question

      @predefined_survey = FactoryGirl.create(:survey, organization: @org)
      ENV['PREDEFINED_SURVEY'] = @predefined_survey.id.to_s
      @campus_question = FactoryGirl.create(:campus_element, content: "SUSD\nUSD")
      @predefined_survey.questions << @campus_question

      @contact1 = FactoryGirl.create(:person)
      @contact2 = FactoryGirl.create(:person)
      @org.add_contact(@contact1)
      @org.add_contact(@contact2)
    end

    should "not search by survey answers by wildcard strings if question is non-fill in the blank question (non-predefined survey)" do
      @answer_sheet1 = FactoryGirl.create(:answer_sheet, survey: @survey, person: @contact1)
      FactoryGirl.create(:answer, answer_sheet: @answer_sheet1, question: @question, value: "DSU", short_value: "DSU")

      @answer_sheet2 = FactoryGirl.create(:answer_sheet, survey: @survey, person: @contact2)
      FactoryGirl.create(:answer, answer_sheet: @answer_sheet2, question: @question, value: "SDSU", short_value: "SDSU")

      xhr :get, :index, {:do_search => "1", "assigned_to"=>"all", "first_name"=>"", "last_name"=>"", "phone_number"=>"", "person_updated_from"=>"", "person_updated_to"=>"", "status"=>"", "survey"=>"", "answers"=>{"#{@question.id}" => "DSU"}, "commit"=>"Search"}

      assert_equal 1, assigns(:people).length
      assert assigns(:people).include? @contact1
      assert assigns(:people).include?(@contact2) == false
    end

    should "not search by survey answers by wildcard strings if question is non-fill in the blank question (predefined survey)" do
      xhr :post, :create, {:person => {:first_name => "Eloisa", :last_name => "Bongalbal", :gender => "female"}, :answers => {"#{@campus_question.id}"=>"DSU"}  }
      assert_equal "DSU", Person.where(first_name: "Eloisa", last_name: "Bongalbal").first.campus

      xhr :post, :create, {:person => {:first_name => "Neil", :last_name => "dela Cruz", :gender => "male"}, :answers => {"#{@campus_question.id}"=>"SDSU"}  }
      assert_equal "SDSU", Person.where(first_name: "Neil", last_name: "dela Cruz").first.campus

      xhr :get, :index, {:do_search => "1", "assigned_to"=>"all", "answers"=>{"#{@campus_question.id}" => "DSU"}, "commit"=>"Search"}

      assert_equal 1, assigns(:people).length
      assert assigns(:people).include?(Person.where(first_name: "Eloisa", last_name: "Bongalbal").first)
      assert !assigns(:people).include?(Person.where(first_name: "Neil", last_name: "dela Cruz").first)
    end
  end

  context "fetching contacts_all" do
    setup do
      @user, @org = admin_user_login_with_org
      @predefined_survey = FactoryGirl.create(:survey, organization: @org)
      ENV['PREDEFINED_SURVEY'] = @predefined_survey.id.to_s
    end
    should "return all contacts without paging" do
      (1..50).each do
        contact = FactoryGirl.create(:person)
        @org.add_contact(contact)
      end
      xhr :get, :contacts_all
      assert_equal 51, assigns(:all_people).length
    end
  end

  context "autosuggest" do
    setup do
      @user, @org = admin_user_login_with_org
      @predefined_survey = FactoryGirl.create(:survey, organization: @org)
      ENV['PREDEFINED_SURVEY'] = @predefined_survey.id.to_s
      @contact1 = FactoryGirl.create(:person, phone_number: '445566778', email:'abcd@email.com')
      @contact2 = FactoryGirl.create(:person, phone_number: '112233445', email:'cdef@email.com')
      @contact3 = FactoryGirl.create(:person, phone_number: '566778899', email:'efgh@email.com')
      @org.add_contact(@contact1)
      @org.add_contact(@contact2)
      @org.add_contact(@contact3)
    end
    should "return matching phone numbers" do
      xhr :get, :auto_suggest_send_text, {:q => "77"}
      results = assigns(:results).collect{|x| x[:id].to_i}
      assert results.include?(@contact1.id)
      assert !results.include?(@contact2.id)
      assert results.include?(@contact3.id)
    end
    should "return matching emails" do
      xhr :get, :auto_suggest_send_email, {:q => "cd"}
      results = assigns(:results).collect{|x| x[:id].to_i}
      assert results.include?(@contact1.id)
      assert results.include?(@contact2.id)
      assert !results.include?(@contact3.id)
    end
  end
end