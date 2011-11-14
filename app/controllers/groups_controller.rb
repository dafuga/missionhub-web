class GroupsController < ApplicationController
  before_filter :get_group
  before_filter :leader_needed, :only => [:create, :new]
  
  def index
    @groups = current_organization.groups
    if params[:label].present?
      @label = current_organization.group_labels.find(params[:label])
      @groups = @groups.where('mh_group_labels.id' => params[:label]).joins(:group_labels)
    else
      @groups = @groups.includes(:group_labels)
    end
  end

  def show
    authorize! :read, @group
  end

  def edit
    authorize! :edit, @group
  end

  def update
    authorize! :update, @group
    if @group.update_attributes(params[:group])
      redirect_to @group
    else
      redirect_to :back
    end
  end
  
  def new
    @group = current_organization.groups.new
  end

  def create
    @group = current_organization.groups.create(params[:group])
    if @group.valid?
      redirect_to @group
    else
      render :new
    end
  end

  def destroy
    authorize! :destroy, @group
    @group.destroy
    redirect_to groups_path
  end

  protected 
  
    def get_group
      @group = Present(current_organization.groups.find(params[:id])) if params[:id]
    end
    
    def leader_needed
      unless is_leader?
        access_denied 
        return false
      end
    end
    
end