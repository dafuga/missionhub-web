$.fn.load_answers = () ->
  survey_id = $("#mass_entry_table").data("survey-id")
  $(".fetching-loader").show()
  $(".saving-loader").hide()
  $("#mass_entry_table").hide()
  $("#mass_entry_table").handsontable("destroy")
  $(".mass_entry_buttons").hide()
  $.getJSON "/surveys/#{survey_id}/mass_entry_data.json", (response)->
    $(".fetching-loader").hide()
    $(".saving-loader").hide()
    $("#mass_entry_table").show()
    $(".mass_entry_buttons").show()
    $("#mass_entry_table").handsontable
      width: $(window).width()
      height: $(window).height()
      autoColumnSize: true
      data: response['data']
      columns: response['settings']
      colHeaders: response['headers']
      rowHeaders: true
      manualColumnResize: true
      nativeScrollbars: true
      stretchH: 'all'
      columnSorting: true
      wordWrap: true
      allowInvalid: true
      minSpareRows: true
      contextMenu: ['undo','redo','remove_row']
      # fixedColumnsLeft: 2
      autoWrapRow: true
      autoWrapCol: true
      fillHandle: false
      beforeKeyDown: (e)->
        if e.which == 9
          cell = $('#mass_entry_table').handsontable('getSelected')
          $('#mass_entry_table').handsontable('selectCell', cell[0], cell[1], cell[2], cell[3], scrollToSelection = true)
      beforeChange: ()->
        $("body").data('has_changes','true')
      cells: (row, col, prop) ->
        cellProperties = {}
        if response['multi_col'].indexOf(col) >= 0
          cellProperties.renderer = Handsontable.renderers.AutocompleteRenderer;
        id = $("#mass_entry_table").handsontable("getDataAtCell", row, 0)
        val = $("#mass_entry_table").handsontable("getDataAtCell", row, col)
        if id == "" || id == null || id == undefined
          cellProperties.readOnly = false
        else if (val == "" || val == null)
          cellProperties.readOnly = false
        # else if (val != "" && val != null) && (col == 1 || col == 2 || col == 3)
        #   cellProperties.readOnly = true
        cellProperties

      
$ ->
  
  $(document).on "keyup", "body", (e)->
    if e.which == 13
      $("#mass_entry_table").handsontable("deselectCell")
          
  $("#mass_entry_table").bind 'scroll', (e)->
    $(window).scroll();
  
  $(document).on "click", ".htSelectEditor option", (e)->
    if $(this).attr('value') == ''
      $(".htSelectEditor").find("option").prop("selected", false)
      $(this).prop("selected", true)
    else
      if $(this).is(":selected")
        $(this).prop("selected", false)
      else
        $(this).prop("selected", true)
        if $(this).attr('value') != ''
          $(".htSelectEditor").find("option[value='']").prop("selected", false)
  
  # if $("#copy_mass_entry").size() > 0
  #   $(document).on "click", "#copy_mass_entry", (e)->
  #     e.preventDefault()
  
  $(document).on "click", ".new_mass_entry", (e)->
    e.preventDefault()
    row = $("#mass_entry_table").handsontable("countRows")-1
    $("#mass_entry_table").handsontable("selectCell", row, 0)
    $(document).scrollTop(9999)
      
  $(document).on "click", ".reload_mass_entry", (e)->
    e.preventDefault()
    if $("body").data("has_changes") == "true"
      if(confirm('Warning! Reloading the Mass Entry table will not save your changes. Save changes before reloading page.'))
        $.fn.load_answers()
  
  $(document).on "click", ".save_mass_entry", (e)->
    e.preventDefault()
    $(".saving-loader").show()
    $("#mass_entry_table").hide()
    $(".mass_entry_buttons").hide()
    survey_id = $("#mass_entry_table").data("survey-id")
    table_val = $("#mass_entry_table").handsontable("getData")
    $.ajax
      type: "POST"
      url: "/surveys/#{survey_id}/mass_entry_save"
      data: {values: table_val}
  
  if $("#mass_entry_table").size() > 0
    $.fn.load_answers()
    
  
  $('#survey_background_color, #survey_text_color').excolor({root_path: '/assets/'})
  false

  $(".file_upload_container .file_field").on "change", () ->
    parent = $(this).parents(".file_upload_container")
    file_name = parent.find(".file_upload_name_container")
    file_name.html($(this).val().split('\\').pop())

  $('#show_advanced_survey_option').live 'click', ()->
    $('#advanced_survey_option').toggle()
    if($('#advanced_survey_option').is(":visible"))
      $(this).html($(this).html().replace("Show","Hide"))
    else
      $(this).html($(this).html().replace("Hide","Show"))

  $('#transfer_survey_content #other_orgs_list .other_org').live 'click', ->
    org_id = $(this).attr('data-org-id')
    org_name = $(this).attr('data-org-name')
    survey_id = $('#transfer_survey_div').attr('data-survey-id')
    survey_name = $('#transfer_survey_div').attr('data-survey-name')
    if(confirm('Are you sure you want to copy ' + survey_name + ' to ' + org_name + ' organization?'))
      $('#transfer_survey_div #transfer_survey_processing #org_name').text(org_name)
      $('#transfer_survey_div #transfer_survey_content').hide()
      $('#transfer_survey_div #transfer_survey_error').hide()
      $('#transfer_survey_div #transfer_survey_processing').show()
      $.ajax
        type: 'GET',
        url: '/copy_survey?survey_id=' + survey_id + '&organization_id=' + org_id

  $('a.transfer_survey').live 'click', (e)->
    e.preventDefault()
    survey_id = $(this).attr('data-id')
    survey_name = $(this).attr('data-name')
    $('#transfer_survey_div #transfer_survey_guide #survey_name').text($(this).attr('data-name'))
    $('#transfer_survey_div').attr('data-survey-id',survey_id)
    $('#transfer_survey_div').attr('data-survey-name',survey_name)
    $.showDialog($("#transfer_survey_div"))
    $('#transfer_survey_div #transfer_survey_processing').hide()
    $('#transfer_survey_div #transfer_survey_error').hide()
    $('#transfer_survey_div #transfer_survey_content').show()
    $("#other_orgs_filter_keyword").removeClass("ui-autocomplete-loading")
    $("#other_orgs_filter_keyword").val("")
    $("#other_orgs_filter_keyword").focus()
    $(".other_org").remove()

  $('#other_orgs_filter_keyword').live 'keyup', ->
    $('#transfer_survey_div #transfer_survey_processing').hide()
    $('#transfer_survey_div #transfer_survey_error').hide()

    keyword = $(this).val().toLowerCase()
    if keyword.length >= 3
      $(this).addClass("ui-autocomplete-loading")
      window.setTimeout (->
        $.ajax
          type: 'GET',
          url: '/show_other_orgs?keyword=' + encodeURIComponent(keyword)
      ), 1000
    else if keyword.length == 0
      $(".other_org").remove()
      $(this).removeClass("ui-autocomplete-loading")