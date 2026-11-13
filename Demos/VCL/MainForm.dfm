object frmMain: TfrmMain
  Left = 0
  Top = 0
  Caption = 'delphi-mcp-forms - VCL demo'
  ClientHeight = 560
  ClientWidth = 780
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  Position = poScreenCenter
  OnCreate = FormCreate
  OnDestroy = FormDestroy
  object lblServer: TLabel
    Left = 16
    Top = 12
    Width = 300
    Height = 15
    Caption = 'MCP server: -'
  end
  object grpOrder: TGroupBox
    Left = 16
    Top = 40
    Width = 420
    Height = 330
    Caption = ' New order '
    TabOrder = 0
    object lblCustomer: TLabel
      Left = 16
      Top = 32
      Width = 100
      Height = 15
      Caption = '&Customer:'
      FocusControl = edtCustomer
    end
    object lblProduct: TLabel
      Left = 16
      Top = 68
      Width = 100
      Height = 15
      Caption = '&Product:'
      FocusControl = cbProduct
    end
    object lblQuantity: TLabel
      Left = 16
      Top = 104
      Width = 100
      Height = 15
      Caption = '&Quantity:'
      FocusControl = spnQuantity
    end
    object lblDelivery: TLabel
      Left = 16
      Top = 140
      Width = 100
      Height = 15
      Caption = '&Delivery date:'
      FocusControl = dtpDelivery
    end
    object lblNotes: TLabel
      Left = 16
      Top = 208
      Width = 100
      Height = 15
      Caption = '&Notes:'
    end
    object edtCustomer: TEdit
      Left = 128
      Top = 28
      Width = 270
      Height = 23
      Hint = 'Customer company name'
      TabOrder = 0
    end
    object cbProduct: TComboBox
      Left = 128
      Top = 64
      Width = 270
      Height = 23
      Style = csDropDownList
      TabOrder = 1
      Items.Strings = (
        'Espresso machine'
        'Coffee grinder'
        'Milk frother'
        'Descaling kit')
    end
    object spnQuantity: TSpinEdit
      Left = 128
      Top = 100
      Width = 80
      Height = 24
      MaxValue = 100
      MinValue = 1
      TabOrder = 2
      Value = 1
    end
    object dtpDelivery: TDateTimePicker
      Left = 128
      Top = 136
      Width = 140
      Height = 23
      TabOrder = 3
    end
    object chkGiftWrap: TCheckBox
      Left = 128
      Top = 172
      Width = 200
      Height = 17
      Caption = 'Gift wrap'
      TabOrder = 4
    end
    object memNotes: TMemo
      Left = 128
      Top = 204
      Width = 270
      Height = 70
      TabOrder = 5
    end
    object btnSave: TButton
      Left = 216
      Top = 288
      Width = 90
      Height = 28
      Caption = '&Save order'
      TabOrder = 6
      OnClick = btnSaveClick
    end
    object btnClear: TButton
      Left = 308
      Top = 288
      Width = 90
      Height = 28
      Caption = 'C&lear'
      TabOrder = 7
      OnClick = btnClearClick
    end
  end
  object lstOrders: TListBox
    Left = 452
    Top = 48
    Width = 312
    Height = 322
    ItemHeight = 15
    TabOrder = 1
  end
  object memLog: TMemo
    Left = 16
    Top = 384
    Width = 748
    Height = 160
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clWindowText
    Font.Height = -12
    Font.Name = 'Consolas'
    Font.Style = []
    ParentFont = False
    ReadOnly = True
    ScrollBars = ssVertical
    TabOrder = 2
  end
end
