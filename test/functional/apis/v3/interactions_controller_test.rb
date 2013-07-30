require 'test_helper'

class Apis::V3::InteractionsControllerTest < ActionController::TestCase
  setup do
    request.env['HTTP_ACCEPT'] = 'application/json'
    @client = Factory(:client)
    @user = Factory(:user_no_org)
    @user1 = Factory(:user_no_org)
    @client.organization.add_admin(@user.person)
    @interaction = Factory(:interaction, organization: @client.organization, receiver: @user.person, creator: @user1.person)
  end

  context '.index' do
    should "return a list of org's interactions" do
      get :index, secret: @client.secret, order: 'created_at'
      assert_response :success
      json = JSON.parse(response.body)
      assert_equal @interaction.id, json['interactions'].last['id'], json.inspect
    end
  end


  context '.show' do
    should 'return an interaction' do
      get :show, id: @interaction.id, secret: @client.secret
      json = JSON.parse(response.body)
      assert_equal @interaction.id, json['interaction']['id']
    end
  end

  context '.create' do
    should 'create and return a interaction' do
      assert_difference "Interaction.count" do
        post :create, interaction: {receiver_id: '1'}, secret: @client.secret
      end
      json = JSON.parse(response.body)
      assert_equal 1, json['interaction']['receiver_id'], json.inspect
    end
  end

  context '.update' do
    should 'update and return a interaction' do
      put :update, id: @interaction.id, interaction: {receiver_id: '5'}, secret: @client.secret
      json = JSON.parse(response.body)
      assert_equal 5, json['interaction']['receiver_id']
    end
  end

  context '.destroy' do
    should 'mark an interaction as deleted' do
      delete :destroy, id: @interaction.id, secret: @client.secret
      @interaction.reload
      assert_not_nil @interaction.deleted_at, @interaction.inspect
    end
    should 'not actually delete an interaction' do
      assert_difference "Interaction.count", 0 do
        delete :destroy, id: @interaction.id, secret: @client.secret
      end
    end
  end



end
