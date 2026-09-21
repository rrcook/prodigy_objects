# Copyright 2026, Ralph Richard Cook & Phillip Heller
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

defmodule StandardMenu do
  @moduledoc """
  Builds the standard-menu call (`XXOPSM00`) that makes a page's numbered
  fields navigate.

  A standard menu is not its own segment type: it is an ordinary
  `ProgramCall` to `XXOPSM00PGM` whose parameters carry the menu. This module
  assembles those parameters so callers do not have to know their order or
  framing.

  ## Where the format came from

  Derived from objects recovered from the service - `NH00CF4JB` and
  `NH00CF4KB`, a working HEADLINE NEWS pair - and cross-checked against the
  parameter framing of simpler calls in `NH000000PG`. `menu_params/1` is
  covered by a test that reproduces `NH00CF4JB`'s segment byte for byte.

  XXOPSM00 itself only interprets P1 and P2; it stores P3 to P6 and hands
  them on to the rest of the menu programs. So the layouts below come from
  the recovered objects rather than from the program.

  Six parameters, in order. `[x:n]` is a field of n bytes; lengths are
  big-endian. A PEV is a field number - the n of TBOL's `&n`.

      P1  processors: [count:1], then that many 13-byte OBJIDs. Only mode 0
          uses them, to name the service's own processor programs.
      P2  mode byte. The recovered HEADLINE NEWS objects use 3.
      P3  next page: [pages:1], then what NEXT reaches from this page - an
          OBJID, optionally followed by a destination parameter (below).
      P4  choice map: [page:1][length:2], then for each numbered choice
          [choice:1][offset of its entry within P6's body:2].
      P5  display attributes: [page:1][length:2][initial cursor PEV:1], then
          for each field [PEV:1][fg:1][bg:1][state:1][0:2], then a 0 byte.
      P6  action list: [page:1][length:2], then for each choice its PEV and
          entry - [PEV:1][action:1][type:1][target OBJID...] - then a 0 byte.

  Each parameter is then length-framed by `ObjectUtils.make_params_buffer/1`
  when the call is encoded.

  ## Navigating with a parameter

  The recovered pair shows how a menu reaches a sibling body without a page
  template of its own: the action navigates to the SHARED page template and
  passes the body to display as the destination parameter. One template
  serves every screen in the application, told each time which element to
  show - which is why the service's caches hold one `NH000000PG` and many
  bodies.
  """

  @menu_program "XXOPSM00PGM"

  # The first two bytes of every P6 entry. Action 1 is Navigate; type 0 is an
  # ordinary field rather than a TTX Assistant MENU field.
  @action_navigate 0x01
  @type_plain 0x00

  # The page byte that leads P4, P5 and P6. Menus built here are single-page.
  @page_one 0x01

  # Colours and state for each field's P5 display entry: foreground 7 on
  # background 0, and state 3, an action field.
  @fg_default 7
  @bg_default 0
  @state_action 3

  @doc """
  An OBJID: an 11-character name, a sequence and a type, as 13 bytes.

  `name` is padded or truncated to 11 characters, so callers may pass the
  bare name.
  """
  @spec objid(binary(), non_neg_integer(), non_neg_integer()) :: binary()
  def objid(name, sequence, type) do
    <<ObjectUtils.edit_length(name, 11)::binary, sequence, type>>
  end

  @doc """
  A destination parameter: the `'P'` tag, a two-byte length, and the payload.

  Used to hand the page template the element it should display.
  """
  @spec destination(binary()) :: binary()
  def destination(payload) when is_binary(payload) do
    # The length counts the payload only, not the tag or the length itself.
    <<?P, byte_size(payload)::16-big, payload::binary>>
  end

  @doc """
  The six parameters of a standard-menu call.

  Options:

    * `:mode` - P2, default 3.
    * `:processors` - P1's OBJIDs, default none. Only mode 0 uses them.
    * `:pages` - the byte that leads P3, default 0.
    * `:next_page` - the rest of P3: what NEXT reaches from this page, as an
      OBJID followed by any destination parameter. The recovered NH00CF4JB has
      empty choice and action lists and uses its menu only to name NH00CF4KB
      as its successor.
    * `:actions` - one target per numbered choice, in choice order: the OBJID
      (plus any destination parameter) that choice navigates to. P4, P5 and
      P6 are all built from this list.
    * `:choice_attrs`, `:display_attrs`, `:action_attrs` - replace P4, P5 or
      P6 outright, if the built ones do not suit.

  With no actions the defaults reproduce NH00CF4JB's parameters exactly.
  """
  @spec menu_params(keyword()) :: [binary()]
  def menu_params(opts \\ []) do
    processors = Keyword.get(opts, :processors, [])
    mode = Keyword.get(opts, :mode, 3)
    pages = Keyword.get(opts, :pages, 0)
    next_page = Keyword.get(opts, :next_page) || <<>>
    targets = Keyword.get(opts, :actions, [])

    # Every choice navigates, so each P6 entry is [Navigate][plain field]
    # followed by the target. P4 and P6 both walk this list, which is what
    # keeps P4's offsets pointing at the right P6 entries.
    entries = Enum.map(targets, &(<<@action_navigate, @type_plain>> <> &1))

    [
      <<length(processors)>> <> IO.iodata_to_binary(processors),
      <<mode>>,
      <<pages>> <> next_page,
      Keyword.get(opts, :choice_attrs) || choice_map(entries),
      Keyword.get(opts, :display_attrs) || display_attrs(length(entries)),
      Keyword.get(opts, :action_attrs) || action_attrs(entries)
    ]
  end

  # Build P4: for each choice, where its entry starts in P6.
  #
  # Choices are numbered from 1 in list order. The offset is measured from
  # the start of P6's body, and each P6 entry takes 1 byte (its PEV) plus the
  # entry itself, so each offset is the running total of the ones before it.
  defp choice_map(entries) do
    {rows, _} =
      Enum.map_reduce(Enum.with_index(entries, 1), 0, fn {e, choice}, off ->
        {<<choice, off::16-big>>, off + 1 + byte_size(e)}
      end)

    body = IO.iodata_to_binary(rows)
    <<@page_one, byte_size(body)::16-big>> <> body
  end

  # Build P5: one display entry per numbered field, 1..count, each drawn as an
  # action field in the default colours. The leading 0 is the initial-cursor
  # PEV byte, as in the recovered objects; the trailing 0 ends the list.
  # With count 0 this is the empty form NH00CF4JB carries.
  defp display_attrs(count) do
    body =
      <<0>> <>
        IO.iodata_to_binary(
          for pev <- 1..count//1, do: <<pev, @fg_default, @bg_default, @state_action, 0::16>>
        ) <> <<0>>

    <<@page_one, byte_size(body)::16-big>> <> body
  end

  # Build P6: each entry prefixed with its choice's PEV (1, 2, ...), then a
  # 0 byte to end the list.
  defp action_attrs(entries) do
    body =
      IO.iodata_to_binary(for {e, pev} <- Enum.with_index(entries, 1), do: <<pev>> <> e) <> <<0>>

    <<@page_one, byte_size(body)::16-big>> <> body
  end

  @doc """
  A `ProgramCall` to the standard menu, ready to add to an object.

  `event` is the program-call event; the recovered objects use
  `:pc_event_post_processor`.
  """
  @spec new(ObjectTypes.pc_event(), keyword()) :: ProgramCall.t()
  def new(event, opts \\ []) do
    # ProgramCall takes the program's name and its type code separately:
    # "XXOPSM00" and "PGM". No embedded object - the menu program is fetched
    # by name.
    ProgramCall.new(
      event,
      :pc_prefix_program_call,
      String.slice(@menu_program, 0, 8),
      String.slice(@menu_program, 8, 3),
      <<>>,
      menu_params(opts)
    )
  end
end
