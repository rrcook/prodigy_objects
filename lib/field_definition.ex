# Copyright 2024, Ralph Richard Cook
#
# This file is part of Prodigy Reloaded.
#
# Prodigy Reloaded is free software: you can redistribute it and/or modify it under the terms of the GNU Affero General
# Public License as published by the Free Software Foundation, either version 3 of the License, or (at your
# option) any later version.
#
# Prodigy Reloaded is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even
# the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License along with Prodigy Reloaded. If not,
# see <https://www.gnu.org/licenses/>.

defmodule FieldDefinition do

  defstruct [
    :segment_type,
    :segment_length,
    :field_state,
    :field_format,
    :origin,
    :size,
    :field_name,
    :text_id,
    :cursor_id,
    :cursor_origin
  ]

  @type t :: %__MODULE__{
    segment_type: ObjectTypes.segment_type(),
    segment_length: non_neg_integer(),
    field_state: ObjectTypes.field_state(),
    field_format: ObjectTypes.field_format(),
    origin: ObjectTypes.xy(),
    size: ObjectTypes.xy(),
    field_name: non_neg_integer(),
    text_id: non_neg_integer(),
    cursor_id: non_neg_integer(),
    cursor_origin: ObjectTypes.xy()
  }

  @doc """
  A field definition with no cursor.

  Recovered objects carry both shapes: `NH00CF4JB` from the service and the
  traced HEADLINE NEWS bodies stop after `text_id`, giving a 13-byte segment,
  while others go on to name a cursor. This is the short form: it is `new/8`
  with no cursor, and the encoder then leaves the cursor bytes off entirely.
  """
  @spec new(ObjectTypes.field_state(), ObjectTypes.field_format(), tuple(), tuple(), non_neg_integer(), non_neg_integer()) :: t()
  def new(field_state, field_format, origin, size, field_name, text_id) do
    new(field_state, field_format, origin, size, field_name, text_id, nil, nil)
  end

  # Pass nil for cursor_id (and cursor_origin) to get the short form described
  # on new/6.
  def new(field_state, field_format, origin, size, field_name, text_id, cursor_id, cursor_origin) do
    # size of "static data" is segment_type = 1, segment_length = 2, pdt_tye = 1

    segment_length =
      1 + # segment_type,
      2 + # segment_length
      1 + # field_state
      1 + # field_format
      3 + # origin x, origin y
      3 + # size x, size y
      1 + # field_name
      1 + # text_id
      cursor_length(cursor_id) # cursor_id and cursor_origin xy, if there is a cursor

    %FieldDefinition{
      segment_type: :field_definition,
      segment_length: segment_length,
      field_state: field_state,
      field_format: field_format,
      origin: origin,
      size: size,
      field_name: field_name,
      text_id: text_id,
      cursor_id: cursor_id,
      cursor_origin: cursor_origin
    }
  end

  # Bytes the cursor adds to the segment: its id (1) and origin (3), or none
  # at all in the short, cursor-less form.
  defp cursor_length(nil), do: 0
  defp cursor_length(_cursor_id), do: 1 + 3

  defimpl ObjectEncoder, for: FieldDefinition do
    use ObjectConstants
    @spec encode(FieldDefinition.t()) :: <<_::32, _::_*8>>
    def encode(%FieldDefinition{} = field_definition) do
      <<
        @segment_value_map[field_definition.segment_type],
        field_definition.segment_length::16-little,
        @field_state_value_map[field_definition.field_state],
        @field_format_value_map[field_definition.field_format],
        ObjectUtils.naplps_coords(field_definition.origin)::binary,
        ObjectUtils.naplps_coords(field_definition.size)::binary,
        field_definition.field_name::8,
        field_definition.text_id::8,
        cursor(field_definition)::binary
      >>
    end

    # The trailing cursor bytes - id, then origin - or nothing for a field
    # built without a cursor (see FieldDefinition.new/6). segment_length above
    # counts the same bytes via cursor_length/1, so the two always agree.
    defp cursor(%FieldDefinition{cursor_id: nil}), do: <<>>

    defp cursor(%FieldDefinition{} = fd),
      do: <<fd.cursor_id::8, ObjectUtils.naplps_coords(fd.cursor_origin)::binary>>
  end
end
