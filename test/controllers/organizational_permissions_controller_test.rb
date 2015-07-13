require 'test_helper'

class OrganizationalPermissionsControllerTest < ActionController::TestCase
  context "Updating contacts" do
    setup do
      @user, @org = admin_user_login_with_org

      @org_permission = FactoryGirl.create(:organizational_permission)
    end

    should "update organizational permission" do
      xhr :put, :update, { :id => @org_permission.id, :status => "" }
      assert_response :success
      assert_not_nil assigns(:organizational_permission)
      assert_equal OrganizationalPermission.find(@org_permission.id), assigns(:organizational_permission)
    end
  end

  context "Updating person permission by all labels " do
    setup do
      @user, @org = admin_user_login_with_org
      @person1 = FactoryGirl.create(:person)
      @org_permission = FactoryGirl.create(:organizational_permission, person: @person1, organization: @org)
    end

    should "archive data" do
      xhr :put, :update_all, { :id => @person1.id, :labels => [@org_permission.id] }
      assert_response :success
      assert_equal 0, assigns(:new_label_set).count
      assert_not_nil OrganizationalPermission.find_by_person_id(@person1.id).archive_date
    end
  end

  context "Moving contacts" do
    setup do
      @user, @org = admin_user_login_with_org
      FactoryGirl.create(:email_address, email: 'user@email.com', person: @user.person)
      @user.person.reload

      @person1 = FactoryGirl.create(:person)
      @person2 = FactoryGirl.create(:person)
      @person3 = FactoryGirl.create(:person)

      @another_org = FactoryGirl.create(:organization)
    end

    should "move the people (contact permissions) from one org to another org (keep contact)" do
      @org.add_contact(@person1)
      @org.add_contact(@person2)
      @org.add_contact(@person3)

      ids = []
      ids << @person1.id
      ids << @person2.id
      ids << @person3.id

      xhr :post, :move_to, { :from_id => @org.id , :to_id => @another_org.id, :ids => ids.join(','), :keep_contact => "true", :current_admin => @user }
      assert_equal ids, @org.contacts.collect(&:id)
      assert_equal ids, @another_org.contacts.collect(&:id)
    end

    should "move the people (contact permissions) from one org to another org (do not keep contact)" do
      @org.add_contact(@person1)
      @org.add_contact(@person2)
      @org.add_contact(@person3)

      ids = []
      ids << @person1.id
      ids << @person2.id
      ids << @person3.id

      xhr :post, :move_to, { :from_id => @org.id , :to_id => @another_org.id, :ids => ids.join(','), :keep_contact => "false", :current_admin => @user }
      assert_equal [], @org.contacts.collect(&:id)
      assert_equal ids, @another_org.contacts.collect(&:id)
    end

    should "move the people (involved permissions) from one org to another org (keep contact)" do
      @org.add_contact(@person1)
      @org.add_contact(@person2)
      @org.add_contact(@person3)
      @org.add_involved(@person1)
      @org.add_involved(@person2)
      @org.add_involved(@person3)

      ids = []
      ids << @person1.id
      ids << @person2.id
      ids << @person3.id

      xhr :post, :move_to, { :from_id => @org.id , :to_id => @another_org.id, :ids => ids.join(','), :keep_contact => "true", :current_admin => @user }
      # for MH-448
      assert_equal ids, @org.people.includes(:organizational_labels).where("organizational_labels.label_id" => Label::INVOLVED_ID).collect(&:id)
      assert_equal ids, @another_org.contacts.collect(&:id)
    end

    should "move the people (involved permissions) from one org to another org (do not keep contact)" do
      @org.add_involved(@person1)
      @org.add_involved(@person2)
      @org.add_involved(@person3)

      ids = []
      ids << @person1.id
      ids << @person2.id
      ids << @person3.id

      xhr :post, :move_to, { :from_id => @org.id , :to_id => @another_org.id, :ids => ids.join(','), :keep_contact => "false", :current_admin => @user }
      # for MH-448
      assert_equal [], @org.people.includes(:organizational_permissions).where("organizational_permissions.permission_id" => Permission.no_permissions.id).collect(&:id)
      assert_equal ids, @another_org.contacts.collect(&:id)
    end

    should "move the people (contact permission + other permissions) from one org to another org (do not keep contact)" do
      @org.add_involved(@person1)
      @org.add_involved(@person2)
      @org.add_involved(@person3)

      @org.add_contact(@person1)
      @org.add_contact(@person2)
      @org.add_contact(@person3)

      ids = []
      ids << @person1.id
      ids << @person2.id
      ids << @person3.id

      xhr :post, :move_to, { :from_id => @org.id , :to_id => @another_org.id, :ids => ids.join(','), :keep_contact => "false", :current_admin => @user }
      # for MH-448
      assert_equal [], @org.contacts.collect(&:id)
      assert_equal [], @org.people.includes(:organizational_permissions).where("organizational_permissions.permission_id" => Permission.user.id).collect(&:id)
      assert_equal ids, @another_org.contacts.collect(&:id)
      assert_equal [], @another_org.people.includes(:organizational_permissions).where("organizational_permissions.permission_id" => Permission.user.id).collect(&:id) # only contact permission will be obtained by the transferred person
    end

    should "not be able to move an admin of current person if he's the only remaining admin in the org" do
      ids = [@user.person.id]

      xhr :post, :move_to, { :from_id => @org.id , :to_id => @another_org.id, :ids => ids.join(','), :keep_contact => "false", :current_admin => @user }

      assert_equal I18n.t('organizational_permissions.cannot_delete_self_as_admin_error'), @response.body
      assert_equal ids, @org.admins.collect(&:id)
      assert_equal [], @another_org.contacts.collect(&:id)
    end

    should "not be able to move to archive if there's only one admin remaining in the org" do
      @another_user = FactoryGirl.create(:user_with_auxs)
      @another_person = @another_user.person
      @org.add_user(@another_person)

      sign_in @another_user

      @org.add_admin(@person3)
      id1 = @user.person.id
      id2 = @person3.id
      ids = [id1, id2]

      xhr :post, :move_to, { :from_id => @org.id , :to_id => @another_org.id, :ids => ids.join(','), :keep_contact => "false"}

      assert_equal I18n.t('organizational_permissions.cannot_delete_admin_error', names: Person.find(ids).collect(&:name).join(", ")), @response.body
      assert @org.admins.collect(&:id).include?(id1)
      assert @org.admins.collect(&:id).include?(id2)
      assert_equal [], @another_org.contacts.collect(&:id)
    end

    should "not be able to move a person to the same org" do
      @another_user = FactoryGirl.create(:user_with_auxs)
      @another_person = @another_user.person
      @org.add_user(@another_person)

      sign_in @another_user

      @org.add_admin(@person3)
      id1 = @user.person.id
      id2 = @person3.id
      ids = [id1, id2]

      xhr :post, :move_to, { :from_id => @org.id , :to_id => @org.id, :ids => ids.join(','), :keep_contact => "false"}

      assert_equal I18n.t('organizational_permissions.moving_to_same_org'), @response.body
      assert @org.admins.collect(&:id).include?(id1)
      assert @org.admins.collect(&:id).include?(id2)
      assert_equal [], @another_org.contacts.collect(&:id)
    end

    should "be able to move an admin person if there's other admins in the org" do
      @user_2 = FactoryGirl.create(:user_with_auxs)
      ids = [@user_2.person.id]
      @org.add_admin(@user_2.person)

      xhr :post, :move_to, { :from_id => @org.id , :to_id => @another_org.id, :ids => ids.join(','), :keep_contact => "false", :current_admin => @user }

      assert_equal I18n.t('organizational_permissions.moving_people_success'), @response.body
      assert_equal [@user.person.id], @org.admins.collect(&:id)
      assert_equal [@user_2.person.id], @another_org.contacts.collect(&:id)
    end

    should "be able to move an leader person" do
      @user_2 = FactoryGirl.create(:user_with_auxs)
      FactoryGirl.create(:email_address, email: 'user2@email.com', person: @user_2.person)
      @user_2.person.reload
      ids = [@user_2.person.id]
      @org.add_leader(@user_2.person, @user.person)
      @contact = FactoryGirl.create(:person)

      assert_difference "ContactAssignment.count", 1 do
        FactoryGirl.create(:contact_assignment, organization: @org, assigned_to: @user_2.person, person: @contact)
        assert_equal 1, @contact.assigned_tos.count
      end

      assert_difference "ContactAssignment.count", -1 do
        xhr :post, :move_to, { :from_id => @org.id , :to_id => @another_org.id, :ids => ids.join(','), :keep_contact => "false", :current_admin => @user }
        assert_equal 0, @contact.assigned_tos.count
      end

      assert_equal I18n.t('organizational_permissions.moving_people_success'), @response.body
      assert_equal [], @org.users.collect(&:id)
      assert_equal [@user_2.person.id], @another_org.contacts.collect(&:id)
    end

    should "completely move an archived person to an org (do not keep contact)" do
      @archived_contact1 = FactoryGirl.create(:person, first_name: "Edmure", last_name: "Tully")
      FactoryGirl.create(:organizational_permission, organization: @user.person.organizations.first, person: @archived_contact1, permission: Permission.no_permissions)
      @archived_contact1.organizational_permissions.where(permission_id: Permission::NO_PERMISSIONS_ID).first.archive #archive his one and only permission

      ids = [@archived_contact1.id]

      xhr :post, :move_to, { :from_id => @org.id , :to_id => @another_org.id, :ids => ids.join(','), :keep_contact => "false", :current_admin => @user }
      assert !@org.people.collect(&:id).include?(@archived_contact1.id)
      assert_equal ids, @another_org.contacts.collect(&:id)
    end
  end

  context "deleting a contact" do
    setup do
      @user, @organization = admin_user_login_with_org
      @organizational_permission = FactoryGirl.create(:organizational_permission, person: @user.person, organization: @organization, :permission => Permission.no_permissions)
      @contact = FactoryGirl.create(:person)
      @permission = FactoryGirl.create(:organizational_permission, person: @contact, organization: @organization, :permission => Permission.no_permissions)
      sign_in @user
    end

    should "make its organizational_permission.followup_status = 'do_not_contact'" do
      a = OrganizationalPermission.where(:followup_status => 'do_not_contact').count
      xhr :put, :update, {:status => "do_not_contact", :id => @permission.id}
      assert_equal a+1, OrganizationalPermission.where(:followup_status => 'do_not_contact').count
      assert_equal [@contact], @organization.dnc_contacts
      assert_not_empty @organization.dnc_contacts.where(id: @contact.id)
    end

    should "delete contact assignments if the permission is 'USER' and change organizational_permission.followup_status to 'do_not_contact'" do
      @organization.remove_contact(@contact)
      @permission = FactoryGirl.create(:organizational_permission, person: @contact, organization: @organization, :permission => Permission.user)

      @contact2 = FactoryGirl.create(:person)
      @organization.add_contact(@contact2)
      @assignment = ContactAssignment.where(person_id: @contact.id, organization_id: @organization.id).first_or_create
      @assignment.update_attributes(assigned_to_id: @contact2.id)

      xhr :put, :update, {:status => "do_not_contact", :id => @permission.id}
      assert_equal 1, OrganizationalPermission.where("deleted_at IS NOT NULL AND organization_id = ? AND person_id = ?", @organization.id, @contact.id).count
      assert_nil ContactAssignment.find_by_person_id_and_organization_id(@contact.id, @organization.id)
    end
  end

  context "set_current" do
    setup do
      @user, @organization = admin_user_login_with_org
      @org_child = FactoryGirl.create(:organization, :name => "neilmarion", :parent => @organization)
    end

    should "set_current" do
      assert_equal @organization.id, session[:current_organization_id]
      xhr :get, :set_current, :id => @org_child.id
      assert_equal @org_child.id.to_s, session[:current_organization_id]
    end
  end

  context "set_primary" do
    setup do
      @user, @organization = admin_user_login_with_org
      @org_child = FactoryGirl.create(:organization, :name => "neilmarion", :parent => @organization)
    end

    should "set_primary" do
      assert_equal @organization.id, session[:current_organization_id]
      xhr :get, :set_primary, :id => @org_child.id
      assert_equal @org_child.id.to_s, session[:current_organization_id]
    end
  end
end